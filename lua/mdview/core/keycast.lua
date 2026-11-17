---@module 'mdview.core.keycast'
--- The keycast overlay's Neovim side: the keys pressed in Neovim, sent to the
--- preview tabs (`/keys`, `\x08`-prefixed), where the keycast overlay shows them
--- as a fading pill. For lectures and screen recordings of a shared preview.
---
--- The capture is not written here: it is ui.nvim's (`ui.screenkey.subscribe`,
--- the same capture, formatting and secret-input protection as the screenkey
--- HUD). mdview binds to it softly (`pcall(require, "ui.screenkey")`); without
--- ui.nvim, or with one that predates `subscribe`, the overlay reports itself
--- unavailable and captures nothing on its own.
---
--- `vim.on_key` (inside ui.screenkey) is attached only while the overlay is on
--- AND a session runs: `:MDView overlay keycast on` before `:MDView start`
--- records the choice, the session's attach starts the capture, its teardown
--- stops it. Keys are sent in batches -- at most one POST per `BATCH_MS` while
--- typing, carrying the whole current line (`sub:text(width)`), never one
--- request per keystroke. After `IDLE_MS` without a key the line starts over,
--- matching the client's fade.
---
--- Privacy: off by default (`browser.overlays.keycast = false`), and the scope
--- `browser.keycast.scope` defaults to "normal" (commands only, no typed text).
--- See docs/FEATURES/PREVIEW.md#keycast-overlay.

local notify = require("lib.nvim.notify").create("").notify

local M = {}

--- The scopes `browser.keycast.scope` takes, as ui.screenkey names them.
M.SCOPES = { "normal", "insert_protected", "all" }

--- How long the keys of one burst are collected before they are sent.
M.BATCH_MS = 120
--- After this long without a key, the next key starts a new line.
M.IDLE_MS = 1500
--- The width of the line, in display columns.
M.WIDTH = 60

---@type Ui.Screenkey.Subscription|nil
local sub = nil
--- Whether a session runs (between the autocmds' attach and teardown).
local session = false
--- Whether a batch is waiting to be sent.
local pending = false
---@type uv.uv_timer_t|nil
local idle_timer = nil

---@internal
---@return table|nil screenkey, string|nil reason
local function screenkey()
  local ok, mod = pcall(require, "ui.screenkey")
  if not ok or type(mod) ~= "table" then
    return nil, "ui.nvim is not installed"
  end
  if type(mod.subscribe) ~= "function" then
    return nil, "this ui.nvim has no ui.screenkey.subscribe (update ui.nvim)"
  end
  return mod, nil
end

---Whether the capture can run: ui.nvim with `ui.screenkey.subscribe` is there.
---@return boolean ok, string|nil reason
function M.available()
  local mod, reason = screenkey()
  return mod ~= nil, reason
end

---Whether keys are being captured right now.
---@return boolean
function M.is_active()
  if sub and type(sub.active) == "function" and not sub:active() then
    sub = nil
  end
  return sub ~= nil
end

---Whether a session runs (between the autocmds' attach and teardown).
---@return boolean
function M.in_session()
  return session
end

---@internal
---@return Ui.Screenkey.Scope
local function scope()
  local browser = require("mdview.config.browser").defaults
  local s = type(browser.keycast) == "table" and browser.keycast.scope or nil
  if s == nil then
    return "normal"
  end
  if not vim.tbl_contains(M.SCOPES, s) then
    notify(
      ("[mdview] browser.keycast.scope must be one of %s, got %s -- using normal"):format(
        table.concat(M.SCOPES, ", "),
        vim.inspect(s)
      ),
      vim.log.levels.WARN
    )
    return "normal"
  end
  return s
end

---@internal
---@return boolean
local function overlay_on()
  local overlays = require("mdview.config.browser").defaults.overlays
  return type(overlays) == "table" and overlays.keycast == true
end

--- The kinds of refused batches this session already reported (once each).
---@type table<string, true>
local said = {}

---@internal
--- What a refused batch means, and how to say it. A relay older than the /keys
--- route answers "404 page not found" (its file server); anything else -- a relay
--- that is restarting (curl exit 7), a 403, a timeout -- is a passing failure and
--- is not blamed on the relay's age.
---@param err string|nil
---@return string kind, string message
local function refusal(err)
  local detail = tostring(err or "?")
  if detail:find("404 page not found", 1, true) then
    return "old_relay",
      "[mdview] keycast: this relay is older than the /keys route, the overlay stays empty. "
        .. "Set dev.binary_path to a current build until the next release"
  end
  return "failed", ("[mdview] keycast: the relay did not take the keys (%s)"):format(detail)
end

---@internal
--- Send the current line to every tab. Nothing without a running relay. A refused
--- batch is reported once per kind and session, so an empty overlay is never a
--- mystery and a run of failures is not a run of messages.
---@param text string
---@return nil
local function send(text)
  if not require("mdview.core.state").get_server() then
    return
  end
  local ok, json = pcall(vim.json.encode, { text = text })
  if not ok then
    return
  end
  require("mdview.adapter.ws_client").send_keys(json, function(sent, err)
    if sent then
      return
    end
    local kind, message = refusal(err)
    if said[kind] then
      return
    end
    said[kind] = true
    vim.schedule(function()
      notify(message, vim.log.levels.WARN)
    end)
  end)
end

---@internal
--- Release the idle timer (the capture stopped).
---@return nil
local function stop_idle()
  if idle_timer then
    idle_timer:stop()
    if not idle_timer:is_closing() then
      idle_timer:close()
    end
    idle_timer = nil
  end
end

---@internal
--- One key arrived: send the line once the batch window is over, and start the
--- line over after a pause. One timer for the pause, restarted per key (no new
--- handle per keystroke).
---@param s Ui.Screenkey.Subscription
---@return nil
local function on_key(_, s)
  if not pending then
    pending = true
    vim.defer_fn(function()
      pending = false
      if sub == s then
        send(s:text(M.WIDTH, { join_chars = true }))
      end
    end, M.BATCH_MS)
  end
  idle_timer = idle_timer or vim.uv.new_timer()
  if idle_timer then
    idle_timer:stop()
    idle_timer:start(
      M.IDLE_MS,
      0,
      vim.schedule_wrap(function()
        if sub == s then
          s:clear()
        end
      end)
    )
  end
end

---@internal
--- Subscribe to ui.screenkey. When that is not possible (no ui.nvim, an old one, or
--- subscribe() raises), say so -- the overlay may be on from setup() -- and capture
--- nothing; the session goes on either way.
---@return boolean started
local function start()
  local mod, reason = screenkey()
  if mod then
    local ok, got = pcall(mod.subscribe, on_key, {
      scope = scope(),
      -- ui.screenkey removed us because on_key raised: forget the handle, so
      -- is_active() tells the truth and the next sync() subscribes again.
      on_drop = function()
        if sub then
          sub = nil
          pending = false
        end
      end,
    })
    if ok and type(got) == "table" then
      sub = got
      return true
    end
    reason = ("ui.screenkey.subscribe failed: %s"):format(tostring(got))
  end
  notify(("[mdview] overlay keycast is unavailable: %s"):format(reason or "?"), vim.log.levels.WARN)
  return false
end

---@internal
---@return nil
local function stop()
  if sub then
    pcall(sub.unsubscribe, sub)
    sub = nil
  end
  pending = false
  stop_idle()
end

---Start or stop the capture so that it runs exactly while the overlay is on and a
---session runs. Called by `:MDView overlay keycast` and by the session's attach.
---@return boolean active
function M.sync()
  if sub and type(sub.active) == "function" and not sub:active() then
    sub = nil -- dropped behind our back (an older ui.nvim without on_drop)
  end
  local want = session and overlay_on()
  if want and not sub then
    start()
  elseif not want and sub then
    stop()
  end
  return sub ~= nil
end

---The session's autocmds were attached (`:MDView start`).
---@return nil
function M.session_started()
  session = true
  said = {}
  M.sync()
end

---The session ended (teardown): the capture stops.
---@return nil
function M.session_ended()
  session = false
  stop()
end

return M
