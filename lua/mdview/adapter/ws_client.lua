---@module 'mdview.adapter.ws_client'
-- wait_ready helper plus the HTTP transport to the relay: health polling, URL
-- building, non-blocking POST, and the retry/queue path.
--
-- Kept as one file: the four concerns are each a single named local with a
-- clear boundary, so splitting them would add cross-file indirection without
-- the independent, multi-consumer payoff that bindings/ or adapter/browser/
-- get from being split.

local fn = vim.fn
-- DEP-01: matches the fallback pattern every other module in this repo
-- already uses -- this repo's stated floor is 0.9+, so a bare vim.uv would
-- break on Neovim < 0.10.
local uv = vim.uv or vim.loop
local normalize = require("mdview.helper.normalize")
local log = require("mdview.helper.log")
local shared_relay = require("mdview.adapter.shared_relay")
local retry_backoff = require("lib.nvim.patterns.retry_backoff")

-- Unlike config/init.lua's and init.lua's plain `create("")` (no popup,
-- follows the future global default), these specific messages are health-
-- check/HTTP failures that can carry a raw stderr dump -- exactly the
-- long/multi-line case a toast is for, so popup is requested explicitly
-- here rather than waiting on that default.
local notify = require("lib.nvim.notify").create("", { popup = true, source = "mdview" }).notify

local M = {}

local DEFAULT_PORT = 43219

-- Built-in readiness wait, used when `transport.health_timeout_ms` is not
-- configured. 15s, not the old 2s: a freshly built or first-run relay binary
-- can take several seconds to bind while the OS/antivirus scans it, and the
-- launcher gates the browser open on this window (it must — the relay also
-- serves the page, so opening before it's up would just load a browser error
-- page). A 2s cap made the tab intermittently never open — the "worked last
-- time" flakiness. Polling ends the moment /health answers, so a healthy
-- relay still opens in well under a second; only a slow start waits.
M.WAIT_READY_TIMEOUT = M.WAIT_READY_TIMEOUT or 15000

--- Timing against the relay process, as one `transport` block rather than
--- four separate keys: they are one decision -- how patient to be with a
--- relay that is slow to answer -- and tuning one without the others is how
--- you end up retrying five times inside a timeout that already expired.
---
--- The defaults suit a local relay on a normal machine. A first-run binary
--- being scanned by antivirus, a busy CI box, or a relay reached over a slow
--- link all want more of every one of them.
---@return { health_poll_ms: integer, health_timeout_ms: integer, max_retries: integer, base_retry_ms: integer }
local function transport()
  local defaults = {
    health_poll_ms = 200,
    health_timeout_ms = M.WAIT_READY_TIMEOUT,
    max_retries = 5,
    base_retry_ms = 150,
  }
  local ok, config = pcall(require, "mdview.config")
  if not ok then
    return defaults
  end
  -- mdview.config exposes the live, merged values as `defaults` (see its
  -- module comment); there is no get()/options accessor.
  local t = type(config.defaults) == "table" and config.defaults.transport or nil
  if type(t) ~= "table" then
    return defaults
  end
  local out = {}
  for key, fallback in pairs(defaults) do
    local n = t[key]
    out[key] = (type(n) == "number" and n > 0) and n or fallback
  end
  return out
end
-- Exposed for tests: the config lookup is otherwise only observable by
-- timing a real relay.
M._transport = transport

M.last_request = {}
M._pending = {} -- pending queue: path -> { markdown=..., tries=0 }
M._is_waiting = false

-- Once the server has answered /health once, remember it so subsequent
-- wait_ready calls (live_push wraps EVERY TextChanged in one) short-circuit
-- instead of doing a curl /health round trip per keystroke. Reset whenever
-- the server process is (re)spawned or stopped (launcher.start / stop.stop).
M._ready = false

--- Forget that the server was seen healthy, so the next M.wait_ready call
--- performs a real /health round trip instead of short-circuiting.
---@return nil
function M.reset_ready()
  M._ready = false
end

-- simple helper to construct /health URL
---@internal
---@param port integer
---@return string
local function health_url(port)
  return string.format("http://localhost:%d/health", port)
end

-- curl is a hard dependency (docs/installation.md); there is no transport
-- without it. Reported as a distinct, non-retryable error rather than as a
-- curl exit code, so wait_ready can fail at once instead of polling until the
-- timeout for a request that was never sent.
local CURL_MISSING = "curl not found on PATH"

-- Exit code handed to a POST callback when curl could not be started at all
-- (jobstart failed); 127 stays reserved for "curl is not installed".
local JOBSTART_FAILED = -1

-- Non-blocking curl GET
---@internal
---@param url string
---@param cb fun(code:integer, err:string|nil) # err is set only when no request was made
---@return nil
local function http_get(url, cb)
  if fn.executable("curl") ~= 1 then
    cb(127, CURL_MISSING)
    return
  end
  local ok, jid = pcall(fn.jobstart, { "curl", "-sS", url }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_exit = function(_, code, _)
      cb(code, nil)
    end,
  })
  if not ok or type(jid) ~= "number" or jid <= 0 then
    -- No on_exit will ever come: report an ordinary failed attempt, so the
    -- health poll retries until its timeout instead of waiting forever.
    cb(JOBSTART_FAILED, nil)
  end
end

--- Wait until server responds on /health or timeout, then call cb(true) /
--- cb(false). Once the server has been seen healthy, later calls short-circuit
--- to cb(true) without another /health round trip (see M.reset_ready).
---@param cb fun(ok:boolean)
---@param timeout_ms integer|nil # explicit override; nil = `transport.health_timeout_ms`
function M.wait_ready(cb, timeout_ms)
  cb = cb or function() end

  if M._ready then
    cb(true)
    return
  end

  local tcfg = transport()
  local timeout = timeout_ms or tcfg.health_timeout_ms
  local start_time = uv.now()
  local attempt = 0

  ---@internal
  ---@return nil
  local function poll()
    attempt = attempt + 1
    local port = vim.g.mdview_server_port or DEFAULT_PORT
    local url = health_url(port)

    http_get(url, function(code, err)
      if err then
        notify("[mdview] server health-check impossible: " .. err, vim.log.levels.ERROR)
        cb(false)
      elseif code == 0 then
        M._ready = true
        log.debug(
          string.format("server ready after %d ms, attempt %d", uv.now() - start_time, attempt),
          nil,
          "ws_client",
          true
        )
        cb(true)
      else
        if (uv.now() - start_time) < timeout then
          -- optionally log every N attempts
          if attempt % 10 == 0 then
            notify(string.format("[mdview] waiting for server, attempt %d...", attempt), vim.log.levels.INFO)
          end
          vim.defer_fn(poll, tcfg.health_poll_ms)
        else
          notify("[mdview] server health-check timed out after " .. tostring(timeout) .. "ms", vim.log.levels.ERROR)
          cb(false)
        end
      end
    end)
  end

  poll()
end

-- internal helper: construct a URL for an mdview-server endpoint,
-- authenticated with the shared session token generated for the currently
-- running process.
---@internal
---@param endpoint string # e.g. "update" or "scroll"
---@param path string # file path being previewed (used as the room key)
---@return string
local function endpoint_url_for(endpoint, path)
  local port = vim.g.mdview_server_port or DEFAULT_PORT
  local normalized = normalize.path_for_url(path)
  local token = require("mdview.core.state").get_token() or ""
  -- On a shared relay every request names this instance: a heartbeat, and for
  -- /update and /doc the claim on the room (see mdview.adapter.shared_relay).
  return string.format("http://localhost:%d/%s?key=%s&token=%s", port, endpoint, normalized, vim.uri_encode(token))
    .. shared_relay.client_param()
end

-- On a shared relay only the instance that owns the tab's room pushes into it
-- (the focused one); the others stay quiet until they take it over.
---@internal
---@return boolean
local function may_push()
  return shared_relay.may_push()
end

---@internal
---@param path string
---@return string
local function update_url_for(path)
  return endpoint_url_for("update", path)
end

---@internal
---@param path string
---@return string
local function scroll_url_for(path)
  return endpoint_url_for("scroll", path)
end

---@internal
---@param path string
---@return string
local function diff_url_for(path)
  return endpoint_url_for("diff", path)
end

---@internal
---@param path string
---@return string
local function spans_url_for(path)
  return endpoint_url_for("spans", path)
end

---@internal
---@param path string
---@return string
local function doc_url_for(path)
  return endpoint_url_for("doc", path)
end

---@internal
---@param path string
---@return string
local function control_url_for(path)
  return endpoint_url_for("control", path)
end

-- Collects stdout/stderr lines and returns them to the callback so caller
-- (try_send_pending) can log the server response body (and quickly detect empty replies).
-- Helper: execute an HTTP POST using curl via jobstart.
-- Callback signature: cb(exit_code:number, stdout_lines:string[]|nil, stderr_lines:string[]|nil)
--
-- The body travels through a temp file and an argv list, never through a
-- shell: it is the user's buffer text, and a shell would run any `$(...)` or
-- backtick span in it. Without curl the POST fails explicitly (a missing tool
-- is a failure, not a success with no response). The same goes for a curl that
-- cannot be started (jobstart answers 0 or -1, or throws): no `on_exit` will ever
-- come, so the callback is invoked right away with exit code JOBSTART_FAILED --
-- a caller that waits on it (the spotlight mirror holds a request back while one
-- is in flight) must not wait forever.
---@internal
---@param url URL # target URL for the POST request
---@param body string # request body content
---@param cb fun(exit_code: integer, stdout_lines: string[]|nil, stderr_lines: string[]|nil)? # optional callback invoked on completion
---@return integer|nil # job ID if curl was started, nil when it was not (cb has been called already)
local function http_post_nonblocking(url, body, cb)
  cb = cb or function() end
  if fn.executable("curl") ~= 1 then
    cb(127, nil, { CURL_MISSING })
    return nil
  end

  local tmpf = fn.tempname()
  local f = io.open(tmpf, "wb")
  if f then
    f:write(body)
    f:close()
  end

  local stdout_acc = {}
  local stderr_acc = {}

  local args = { "-sS", "-X", "POST", url, "--data-binary", "@" .. tmpf, "-H", "Content-Type: text/markdown" }
  local ok_start, jid = pcall(fn.jobstart, vim.list_extend({ "curl" }, args), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data, _)
      if data and #data > 0 then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(stdout_acc, line)
          end
        end
      end
    end,
    on_stderr = function(_, data, _)
      if data and #data > 0 then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(stderr_acc, line)
          end
        end
      end
    end,
    on_exit = function(_, code, _)
      pcall(function()
        os.remove(tmpf)
      end)
      -- pass collected stdout/stderr to callback
      cb(code, (#stdout_acc > 0) and stdout_acc or nil, (#stderr_acc > 0) and stderr_acc or nil)
    end,
  })
  if not ok_start or type(jid) ~= "number" or jid <= 0 then
    pcall(os.remove, tmpf)
    local reason = ok_start and ("jobstart returned " .. tostring(jid)) or tostring(jid)
    cb(JOBSTART_FAILED, nil, { "could not start curl: " .. reason })
    return nil
  end
  return jid
end

-- ---------------------------------------------------------------------------
-- Ordered lanes. Every POST is its own curl process, and two processes started
-- a few milliseconds apart reach the relay in whichever order Windows (and its
-- virus scanner) happens to finish starting them. For the room's content that
-- can leave an older text as the relay's LastPayload; for /control a stale
-- `{"selection":false}` can land after the new selection. So the posts of one
-- room and one channel go through a lane: at most one curl in flight, the rest
-- queued in order. While queued, a full state replaces what it supersedes, so
-- a burst costs two curls (the one in flight and the newest), not one per push.
-- ---------------------------------------------------------------------------

-- A curl that neither answers nor exits must not hold its lane for ever: after
-- this long the next entry goes out anyway (the relay is local; a healthy POST
-- takes milliseconds, a slow first start a few hundred).
M.LANE_STALL_MS = M.LANE_STALL_MS or 5000

---@class mdview.ws_client.LaneEntry
---@field url string
---@field body string
---@field cb fun(exit_code: integer, stdout_lines: string[]|nil, stderr_lines: string[]|nil)|nil
---@field supersedes boolean|nil # a full state: every entry queued before it is dropped
---@field merge_key string|nil # a queued entry with the same merge_key is dropped in favour of this one
---@field on_drop fun()|nil # called when the entry is dropped without being sent

---@class mdview.ws_client.Lane
---@field busy boolean
---@field token table|nil # identifies the in-flight post, so a late exit after the stall watchdog is ignored
---@field queue mdview.ws_client.LaneEntry[]

---@type table<string, mdview.ws_client.Lane>
M._lanes = {}

---@param entry mdview.ws_client.LaneEntry
local function drop_entry(entry)
  if entry.on_drop then
    pcall(entry.on_drop)
  end
end

---@param name string
local function lane_pump(name)
  local lane = M._lanes[name]
  if not lane or lane.busy then
    return
  end
  local entry = table.remove(lane.queue, 1)
  if not entry then
    M._lanes[name] = nil
    return
  end
  local token = {}
  lane.busy, lane.token = true, token
  local function release()
    if lane.token ~= token then
      return -- already released (stall watchdog) or the lanes were reset
    end
    lane.busy, lane.token = false, nil
    lane_pump(name)
  end
  http_post_nonblocking(entry.url, entry.body, function(code, stdout_lines, stderr_lines)
    local ok, err = true, nil
    if entry.cb then
      ok, err = pcall(entry.cb, code, stdout_lines, stderr_lines)
    end
    release()
    if not ok then
      error(err, 0)
    end
  end)
  if lane.token == token then
    vim.defer_fn(release, M.LANE_STALL_MS)
  end
end

--- Queue a POST on lane `name` and send it as soon as the lane is free.
---@param name string
---@param entry mdview.ws_client.LaneEntry
---@return nil
local function lane_post(name, entry)
  local lane = M._lanes[name]
  if not lane then
    lane = { busy = false, queue = {} }
    M._lanes[name] = lane
  end
  local kept = {}
  for _, queued in ipairs(lane.queue) do
    if entry.supersedes or (entry.merge_key ~= nil and queued.merge_key == entry.merge_key) then
      drop_entry(queued)
    else
      kept[#kept + 1] = queued
    end
  end
  kept[#kept + 1] = entry
  lane.queue = kept
  lane_pump(name)
end

---@param channel "content"|"control"|"spans"|"doc"|"scroll"
---@param key string
---@return string
local function lane_name(channel, key)
  return channel .. "\0" .. normalize.path_for_url(key)
end

--- Drop every queued (not yet sent) lane entry; called on :MDView stop. A post
--- already in flight finishes on its own, its exit no longer starts anything.
---@return nil
function M.reset_lanes()
  for _, lane in pairs(M._lanes) do
    for _, queued in ipairs(lane.queue) do
      drop_entry(queued)
    end
    lane.queue, lane.token, lane.busy = {}, nil, false
  end
  M._lanes = {}
end

-- Replace or augment try_send_pending callback handling to log response body.
---@internal
---@param path string # file path whose pending markdown should be sent
---@return nil
local function try_send_pending(path)
  -- English comment: normalize incoming path and bail out if normalization fails
  local norm_path = normalize.path(path)
  if norm_path then
    path = norm_path
  else
    log.debug("[mdvview.ws_client] normalized path is nil", vim.log.levels.ERROR, "ws_client", true)
    return
  end

  local entry = M._pending[path]
  if not entry then
    return
  end
  entry.tries = (entry.tries or 0) + 1

  local url = update_url_for(path)
  local function on_exit(code, stdout_lines, stderr_lines)
    if M._pending[path] ~= entry then
      return -- superseded by a newer push while this one was out: that one is (or was) sent
    end
    if code == 0 then
      -- success: clear queue
      M._pending[path] = nil
      vim.schedule(function()
        local body = stdout_lines and table.concat(stdout_lines, "\n"):sub(1, 200) or "(empty body)"
        log.debug("queued post success for " .. tostring(url) .. " -> " .. body, nil, "ws_client", true)
      end)
    else
      -- failure: retry/backoff as before
      if stderr_lines and #stderr_lines > 0 then
        -- schedule error message to avoid fast-event restrictions
        vim.schedule(function()
          notify("[mdview.ws_client] http_post stderr: " .. table.concat(stderr_lines, "\n"), vim.log.levels.ERROR)
        end)
      end
      if entry.tries < (entry.max_retries or transport().max_retries) then
        local delay = retry_backoff.delay(entry.tries, {
          base_ms = transport().base_retry_ms,
          factor = 2,
          max_ms = math.huge,
        })
        vim.defer_fn(function()
          try_send_pending(path)
        end, delay)
      else
        M._pending[path] = nil
        -- schedule final failure notification
        vim.schedule(function()
          notify(
            "[mdview.ws_client] failed to send markdown for "
              .. tostring(path)
              .. " after "
              .. tostring(entry.tries)
              .. " attempts",
            vim.log.levels.ERROR
          )
        end)
      end
    end
  end
  lane_post(lane_name("content", path), {
    url = url,
    body = entry.markdown,
    cb = on_exit,
    supersedes = true,
    on_drop = function()
      if M._pending[path] == entry then
        M._pending[path] = nil
      end
    end,
  })
end

-- Public: send markdown to server.
-- Non-blocking; retries on failure with exponential backoff.
---@param path string absolute file path (used as key)
---@param markdown string file content
---@param opts table|nil { max_retries?: integer, immediate?: boolean }
---@return nil
function M.send_markdown(path, markdown, opts)
  opts = opts or {}
  if type(path) ~= "string" or type(markdown) ~= "string" or not may_push() then
    return
  end

  if opts.immediate then
    -- Through the room's content lane: a full text supersedes whatever of the
    -- room is still queued, and it cannot overtake the post already in flight.
    local function on_exit(code, stdout_lines, stderr_lines)
      if code == 0 then
        vim.schedule(function()
          local body = stdout_lines and table.concat(stdout_lines, "\n"):sub(1, 200) or "(empty body)"
          log.debug("immediate post success -> " .. body, nil, "ws_client", true)
        end)
      else
        vim.schedule(function()
          if stderr_lines and #stderr_lines > 0 then
            notify(
              "[mdview.ws_client] immediate post stderr: " .. table.concat(stderr_lines, "\n"),
              vim.log.levels.ERROR
            )
          else
            notify("[mdview.ws_client] immediate post failed for " .. path, vim.log.levels.ERROR)
          end
        end)
      end
    end
    lane_post(
      lane_name("content", path),
      { url = update_url_for(path), body = markdown, cb = on_exit, supersedes = true }
    )
    return
  end

  -- Coalesce rapid updates in _pending queue
  M._pending[path] = {
    markdown = markdown,
    tries = 0,
    max_retries = opts.max_retries or transport().max_retries,
  }

  try_send_pending(path)
end

-- Public: send the current cursor line + total line count for `path`'s
-- preview, so the browser tab can scroll to follow (nvim-to-browser half of
-- bidirectional scrolling). Fire-and-forget — no retry queue, since a scroll
-- position is a frequently-superseded transient signal, not durable content;
-- if one ping is lost the next cursor move corrects it.
---@param path string
---@param line integer # 1-based current cursor line
---@param total integer # total line count in the buffer
---@param viewfrac number|nil # desired 0..1 vertical position of the line in the browser viewport
---@param col integer|nil # 0-based byte column of the cursor (for the cursor caret)
function M.send_scroll(path, line, total, viewfrac, col)
  if type(path) ~= "string" or path == "" or not may_push() then
    return
  end
  local body = tostring(line) .. "/" .. tostring(total)
  -- col rides in the 4th field, which requires the 3rd (viewfrac) to be
  -- present as a placeholder so positions line up on the client.
  if type(viewfrac) == "number" then
    body = body .. "/" .. ("%.4f"):format(viewfrac)
  elseif type(col) == "number" then
    body = body .. "/0"
  end
  if type(col) == "number" then
    body = body .. "/" .. tostring(col)
  end
  -- Through a lane per room: an older position landing after a newer one
  -- would jump the tab back. Each position is the whole state, so a queued
  -- one is superseded -- holding `j` costs two curls, not one per line.
  lane_post(lane_name("scroll", path), { url = scroll_url_for(path), body = body, supersedes = true })
  -- The tabs of other display languages show the same lines: they scroll with it.
  for _, follower in ipairs(require("mdview.core.lang_rooms").followers(path)) do
    lane_post(lane_name("scroll", follower), { url = scroll_url_for(follower), body = body, supersedes = true })
  end
end

-- ---------------------------------------------------------------------------
-- Opt-in line-diff transport (experimental.line_diff). Full snapshots go via
-- /update (stored as the relay's LastPayload so late-joiners get whole text);
-- incremental diffs go via /diff (ephemeral). Both are \x03-tagged JSON
-- envelopes carrying a monotonic version so the client (src/client/render/
-- diffDoc.ts) can apply diffs in order and resync from a full on any mismatch.
-- ---------------------------------------------------------------------------

-- Force a full snapshot at least this often so a client that dropped/reordered
-- a diff (and desynced) self-heals within a bounded number of edits.
local FULL_EVERY = 25

-- Per room-key transport state for the diff path.
M._diff_ver = {} -- last version number sent for a key
M._diff_last = {} -- last full line array sent for a key (diff basis)
M._diff_since = {} -- diffs sent since the last full for a key

--- Reset the diff-transport bookkeeping for one key (or all when key is nil),
--- so the next send for it starts with a fresh full snapshot. Called on stop
--- and whenever the previewed document changes rooms.
---@param key string|nil
---@return nil
function M.reset_diff_state(key)
  if key then
    M._diff_ver[key] = nil
    M._diff_last[key] = nil
    M._diff_since[key] = nil
  else
    M._diff_ver = {}
    M._diff_last = {}
    M._diff_since = {}
  end
end

---@internal
---@return boolean
local function line_diff_enabled()
  local ok, exp = pcall(function()
    return require("mdview.config").defaults.experimental
  end)
  return ok and type(exp) == "table" and exp.line_diff == true
end

-- Public: send the current content of `key`'s room as `lines`. With
-- experimental.line_diff off this is a plain full-text push (unchanged wire
-- format). With it on, sends a versioned full snapshot when needed (first send,
-- forced, or every FULL_EVERY edits) and a minimal line diff otherwise.
---@param key string # room key (normalized path)
---@param lines string[] # current buffer lines
---@param opts { full?: boolean }|nil
---@return nil
function M.send_content(key, lines, opts)
  opts = opts or {}
  if type(key) ~= "string" or key == "" or not may_push() then
    return
  end
  lines = lines or {}

  if not line_diff_enabled() then
    -- legacy path: push the whole document as raw text (unchanged wire format)
    M.send_markdown(key, table.concat(lines, "\n"), { immediate = true })
    return
  end

  local ver = M._diff_ver[key]
  local last = M._diff_last[key]
  local since = M._diff_since[key] or 0
  local force_full = opts.full == true or ver == nil or last == nil or since >= FULL_EVERY

  if force_full then
    local nv = (ver or 0) + 1
    local env = "\3" .. vim.json.encode({ t = "f", v = nv, text = table.concat(lines, "\n") })
    M.send_markdown(key, env, { immediate = true }) -- via /update -> LastPayload
    M._diff_ver[key] = nv
    M._diff_last[key] = lines
    M._diff_since[key] = 0
    return
  end

  local edit = require("mdview.utils.line_diff")(last, lines)
  if not edit then
    return -- no change
  end
  local nv = ver + 1
  local env = "\3" .. vim.json.encode({ t = "d", v = nv, base = ver, edits = { edit } })
  -- via /diff (ephemeral). Same lane as the room's fulls: a diff builds on the
  -- version before it, so it must neither overtake that one nor be overtaken.
  lane_post(lane_name("content", key), { url = diff_url_for(key), body = env })
  M._diff_ver[key] = nv
  M._diff_last[key] = lines
  M._diff_since[key] = since + 1
end

-- Public: tell the preview tab(s) of `key`'s room which document is now shown
-- (`doc_path`), so the client can maintain browser history for Back/Forward.
-- Fire-and-forget; sent only when the previewed document actually changes.
---@param key string # room key the tab watches
---@param doc_path string # absolute path of the now-previewed document
---@return nil
function M.send_doc(key, doc_path)
  if type(key) ~= "string" or key == "" or type(doc_path) ~= "string" or doc_path == "" or not may_push() then
    return
  end
  -- FIFO lane, nothing superseded: every switch is a history entry of its
  -- own, and two quick switches must not arrive swapped.
  lane_post(lane_name("doc", key), { url = doc_url_for(key), body = doc_path })
end

-- Control objects are partial (`{"zoom":1.2}` says nothing about the cursor),
-- so queued ones are sent in order, none dropped -- except a selection: a
-- `{"selection":…}` alone is the whole selection state, so a newer one replaces
-- a still-queued older one (a drag in visual mode would otherwise queue up).
---@param json string
---@return string|nil
local function control_merge_key(json)
  local ok, obj = pcall(vim.json.decode, json)
  if ok and type(obj) == "table" and obj.selection ~= nil and next(obj, next(obj)) == nil then
    return "selection"
  end
  return nil
end

-- Public: push a live preview-control update (a small JSON string, e.g.
-- '{"cursor":"caret"}' or '{"zoom":1.2}') to `key`'s room, so runtime commands
-- change the open tab without a reload. Fire-and-forget — a control update is a
-- transient signal; if one is lost the next command (or a reopen with the URL
-- params) corrects it.
---@param key string # room key the tab watches
---@param json string # a small JSON control object
---@return nil
function M.send_control(key, json)
  if type(key) ~= "string" or key == "" or type(json) ~= "string" or json == "" then
    return
  end
  lane_post(lane_name("control", key), { url = control_url_for(key), body = json, merge_key = control_merge_key(json) })
end

--- Public: push the buffer's own fenced-code highlighting to `key`'s room, so
--- the preview can paint code blocks with exactly what Neovim shows
--- (browser.highlighter = "nvim"). `json` is the payload built by
--- mdview.core.fence_spans; pass nil to tell the tab there is nothing to paint,
--- which drops it back to its own JavaScript highlighter.
---
--- Fire-and-forget, but NOT ephemeral on the relay's side: it stores the last
--- one per room and replays it to a joining tab, so a reload does not show the
--- document unhighlighted until the next edit.
---@param key string # room key the tab watches
---@param json string|nil # the fence-highlight payload, or nil for "nothing to paint"
---@return nil
function M.send_spans(key, json)
  if type(key) ~= "string" or key == "" or not may_push() then
    return
  end
  -- Through a lane per room: the relay stores the last spans and replays them
  -- to joining tabs, so an older payload overtaking a newer one would paint
  -- code blocks wrong until the next edit. A payload is the whole state.
  local body = json or "null"
  lane_post(lane_name("spans", key), { url = spans_url_for(key), body = body, supersedes = true })
  -- The fences are the buffer's and no line moves in a translation: the tabs of other languages paint the same spans.
  for _, follower in ipairs(require("mdview.core.lang_rooms").followers(key)) do
    lane_post(lane_name("spans", follower), { url = spans_url_for(follower), body = body, supersedes = true })
  end
end

--- Public: push the spotlight-mirror state (spotlight.nvim's whole-file
--- highlights and their colors, built by mdview.core.spotlight_mirror) to the
--- relay, which fans it out to every preview tab and remembers it for tabs that
--- join or reload later.
---
--- Unlike every other sidecar this takes no room key: the spotlights belong to
--- the editor, not to a document, and apply to whatever each tab is showing.
---
--- `cb` reports whether the relay took it. `curl -sS` exits 0 on an HTTP error
--- too, so success is "exit 0 AND an empty body" -- a relay older than the
--- `/spotlight` route answers its static file server's "404 page not found",
--- which the caller reports once as the actionable thing it is.
---@param json string # the encoded Mdview.SpotlightPayload
---@param cb fun(ok: boolean, err: string|nil)|nil
---@return nil
function M.send_spotlight(json, cb)
  cb = cb or function() end
  if type(json) ~= "string" or json == "" then
    cb(false, "empty payload")
    return
  end
  local port = vim.g.mdview_server_port or DEFAULT_PORT
  local token = require("mdview.core.state").get_token() or ""
  local url = string.format("http://localhost:%d/spotlight?token=%s", port, vim.uri_encode(token))
  http_post_nonblocking(url, json, function(code, stdout_lines, stderr_lines)
    if code == 0 and not stdout_lines then
      cb(true, nil)
      return
    end
    local detail = table.concat(stdout_lines or stderr_lines or { "curl exit " .. tostring(code) }, " "):sub(1, 200)
    cb(false, detail)
  end)
end

-- Public: ask every connected preview tab to close itself (the relay
-- broadcasts a close signal to all rooms; the client calls window.close()).
-- Used by :MDView stop so tabs opened in the OS default browser — which mdview
-- can't close via a process handle — close cooperatively.
--
-- Intentionally BLOCKING with a short timeout: it runs right before the relay
-- process is killed, so a fire-and-forget POST would race the shutdown and
-- usually lose. A brief synchronous curl guarantees the relay broadcasts the
-- signal before it dies. Best-effort — any failure is swallowed (the tab just
-- stays open, exactly as it did before this feature).
---@return nil
function M.send_close()
  if fn.executable("curl") ~= 1 then
    return
  end
  local port = vim.g.mdview_server_port or DEFAULT_PORT
  local token = require("mdview.core.state").get_token() or ""
  local url = string.format("http://localhost:%d/close?token=%s", port, vim.uri_encode(token))
  pcall(fn.system, { "curl", "-sS", "--max-time", "1", "-X", "POST", url })
end

--- Decode the `tabs` list of a relay status answer (GET /attach); nil when the
--- body is no such answer.
---@param body string|nil
---@return string[]|nil
function M.parse_tab_rooms(body)
  if type(body) ~= "string" or body == "" then
    return nil
  end
  local ok, st = pcall(vim.json.decode, body)
  if not ok or type(st) ~= "table" or type(st.tabs) ~= "table" then
    return nil
  end
  local rooms = {}
  for _, room in ipairs(st.tabs) do
    if type(room) == "string" and room ~= "" then
      rooms[#rooms + 1] = room
    end
  end
  return rooms
end

-- Public: the rooms that have a connected preview tab, as the relay reports
-- them. Every relay answers `GET /attach` with its status (the shared relay
-- uses it as the heartbeat); without a `client` parameter the request is no
-- heartbeat and changes nothing. Non-blocking: `cb(rooms)` runs on the main
-- loop, `cb(nil)` when the relay gave no usable answer (curl missing, an older
-- relay without the endpoint, no session).
---@param cb fun(rooms: string[]|nil)
---@return nil
function M.tab_rooms(cb)
  local token = require("mdview.core.state").get_token()
  if fn.executable("curl") ~= 1 or type(token) ~= "string" or token == "" then
    cb(nil)
    return
  end
  local port = vim.g.mdview_server_port or DEFAULT_PORT
  local url = string.format("http://localhost:%d/attach?token=%s", port, vim.uri_encode(token))
  local out = {}
  local ok, jid = pcall(fn.jobstart, { "curl", "-sS", "--max-time", "2", url }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      out = data or {}
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        cb(code == 0 and M.parse_tab_rooms(table.concat(out, "\n")) or nil)
      end)
    end,
  })
  if not ok or type(jid) ~= "number" or jid <= 0 then
    cb(nil)
  end
end

return M
