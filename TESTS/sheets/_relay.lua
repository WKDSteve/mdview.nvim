-- TESTS/sheets/_relay.lua -- the setup of the feature sheets that run the real relay (mdview-preview, -shared-relay,
-- -standalone, -health, -diagnose, -paragraph-tabs). Not a sheet (`testing.sheet` only reads *.sheet.lua); the first
-- step of such a sheet runs `dofile(vim.fn.getcwd() .. "/TESTS/sheets/_relay.lua").setup({ ... })`, the child's cwd
-- is the project root. The directory is in the spec's @cache-inputs.
--
-- Unlike the binding sheets (_bindings.lua), nothing of the transport is replaced: these sheets exist so that
-- `testing perf` sees the processes a preview really starts -- the relay, the curl of every push, the curl of the
-- browser->Neovim poll (inbound_poll, every 250 ms) and the short blocking curls of /health, /close and /attach.
--
-- * The relay is the one built inside this checkout (`node scripts/build-go.mjs` or `npm run build:go` writes
--   native/server/mdview-server[.exe]; CI builds it before the suite). A sheet `requires` it: without a build it is a
--   reported skip, never a download of the release (adapter/install would fetch it from GitHub).
-- * It listens on a free port of 127.0.0.1 picked here, so a preview the user runs on 43219 is never touched.
-- * The client bundle is a stand-in page in a temp folder (`dev.web_root`): no sheet loads it, the browser is the
--   recording stand-in `mdview-sheet-browser` (`fakes`) in "isolated" mode, as in _bindings.lua.
-- * A browser click is played by `_G.browser_tick(line)`: the request the client sends for a ticked checkbox
--   (POST /toggle), made with curl from the sheet (the sheet's preparation in `testing perf`).
--
-- Messages: vim.notify is a recorder (`_G.msgs`); `_G.heard(text)` says whether any message so far contains `text`.

-- luacheck: globals vim
---@diagnostic disable: duplicate-set-field

local M = {}

---@type { msg: string, level: integer? }[]
_G.msgs = {}

---Whether any message so far contains `text` (plain).
---@param text string
---@return boolean
function _G.heard(text)
  for _, m in ipairs(_G.msgs) do
    if m.msg:find(text, 1, true) then
      return true
    end
  end
  return false
end

---The relay binary of this checkout, or nil (the `requires` of the sheets).
---@return string|nil
function M.relay_binary()
  return require("mdview.adapter.server_args").local_built_binary()
end

---A port of 127.0.0.1 nobody listens on right now, between 20000 and 39999. Not one the system hands out for port 0:
---that comes from the ephemeral range (on Windows up to 65535), and `:MDView standalone` listens on
---`server_port + 100`, which must still be a port.
---@return integer
function M.free_port()
  for _ = 1, 100 do
    local port = math.random(20000, 39999)
    local tcp = assert(vim.uv.new_tcp())
    local ok = tcp:bind("127.0.0.1", port)
    tcp:close()
    if ok then
      return port
    end
  end
  error("no free port of 127.0.0.1 between 20000 and 39999")
end

---@param opts? { experimental?: table, shared?: boolean, idle_timeout_s?: integer, browser?: table }
---@return boolean
function M.setup(opts)
  opts = opts or {}

  vim.opt.shortmess:append("I")
  vim.o.swapfile = false
  _G.msgs = {}
  vim.notify = function(msg, level)
    _G.msgs[#_G.msgs + 1] = { msg = tostring(msg), level = level }
  end

  -- The fixture: a Markdown file with two task-list items (realpath: on macOS tempname() is below /var, a link to
  -- /private/var, and mdview keys a document by its resolved path).
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  tmp = vim.fs.normalize(vim.uv.fs_realpath(tmp) or tmp)
  _G.fixture = tmp
  vim.g.mdview_sheet_fixture = tmp
  vim.fn.writefile(
    { "# Alpha", "", "- [ ] first task", "- [ ] second task", "", "## Beta", "", "text" },
    tmp .. "/doc.md"
  )

  local web = tmp .. "/web"
  vim.fn.mkdir(web, "p")
  vim.fn.writefile({ "<!doctype html><title>mdview sheet</title>" }, web .. "/index.html")

  _G.port = M.free_port()

  require("mdview").setup({
    deps_popup = false,
    server_port = _G.port,
    dev = { web_root = web },
    browser = vim.tbl_extend("force", {
      highlighter = "hljs",
      focus = "nvim",
      cursor_marker = "caret",
      open_mode = "isolated",
      browser_cmd = "mdview-sheet-browser",
      -- The stand-in exits at once; a real browser stays, so its exit must not end the session.
      stop_on_browser_exit = false,
      -- A CI machine has no DISPLAY; the stand-in needs none.
      require_display = false,
    }, opts.browser or {}),
    experimental = opts.experimental or {},
    shared_relay = { enabled = opts.shared == true, idle_timeout_s = opts.idle_timeout_s },
  })
  return true
end

---Open the fixture document in the current window.
---@return boolean
function _G.open_doc()
  vim.cmd.edit(vim.fn.fnameescape(_G.fixture .. "/doc.md"))
  return vim.bo.filetype == "markdown"
end

---The session is up and the relay answered /health (or /attach).
---@return boolean
function _G.relay_ready()
  return require("mdview.core.state").get_server() ~= nil and require("mdview.adapter.ws_client")._ready == true
end

---The calls of the browser stand-in.
---@return { argv: string[] }[]
function _G.browser()
  return require("testing.fake_programs").read(vim.env.TESTING_FAKES, "mdview-sheet-browser")
end

---`http://127.0.0.1:<port>/<route>?token=<token>` of the running session, plus `query` (already encoded).
---@param route string
---@param query? string
---@return string
function _G.relay_url(route, query)
  local port = vim.g.mdview_server_port or _G.port
  local token = require("mdview.core.state").get_token() or ""
  return ("http://127.0.0.1:%d/%s?token=%s%s"):format(port, route, vim.uri_encode(token), query or "")
end

---What the preview tab sends when a checkbox on `line` is ticked: POST /toggle for the room of the current buffer.
---@param line integer
---@return boolean
function _G.browser_tick(line)
  local key = require("mdview.core.state").get_preview_key() or require("mdview.helper.target_key").resolve(0)
  local doc = vim.api.nvim_buf_get_name(0)
  local query = ("&key=%s&doc=%s"):format(vim.uri_encode(key), vim.uri_encode(doc))
  _G.tick_result = nil
  vim.system(
    -- 204 has no body: stdout is the status code alone.
    {
      "curl",
      "-sS",
      "--max-time",
      "2",
      "-w",
      "%{http_code}",
      "-X",
      "POST",
      "--data-binary",
      line .. ":1",
      _G.relay_url("toggle", query),
    },
    { text = true },
    function(res)
      _G.tick_result = vim.trim(res.stdout or "")
    end
  )
  return true
end

---Whether the current buffer contains `text` (plain).
---@param text string
---@return boolean
function _G.buf_has(text)
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find(text, 1, true) ~= nil
end

---Another Neovim instance's shared relay: the relay of this checkout started with `--shared` and the discovery file
---of this sandbox, as the first `:MDView start` of another instance leaves it. `_G.other_exit` is its exit code once
---it ended.
---@return boolean
function _G.other_instance()
  local web = _G.fixture .. "/web"
  local shared = require("mdview.adapter.shared_relay")
  vim.fn.mkdir(vim.fs.dirname(shared.discovery_path()), "p")
  _G.other_exit = nil
  _G.other = vim.system({
    M.relay_binary(),
    "--port",
    tostring(_G.port),
    "--token",
    "sheet-other-instance-token",
    "--web-root",
    web,
    "--shared",
    "--discovery-file",
    shared.discovery_path(),
    -- Short, so the relay also ends when the detach of `:MDView stop` did not reach it (the blocking POST /detach
    -- has one second, and a curl to localhost loses 200 ms and more on Windows before it tries 127.0.0.1).
    "--idle-timeout",
    "5",
  }, { text = true }, function(res)
    _G.other_exit = res.code
  end)
  return true
end

---A pid no process has right now (`uv.kill(pid, 0)` fails with ESRCH), counting down from a high one.
---@return integer
local function dead_pid()
  for pid = 4000000, 3000000, -4 do
    local ok, _, name = vim.uv.kill(pid, 0)
    if ok ~= 0 and name == "ESRCH" then
      return pid
    end
  end
  error("no unused pid found")
end

---The discovery file a shared relay leaves when it crashed: its pid is gone, and its port is held by another program
---that accepts a connection but never answers HTTP (`_G.silent`, a server of this editor; a closed port is refused at
---once over libuv, so only a silent listener makes a probe wait for its limit). `_G.stale` is what the file says.
---@return boolean
function _G.stale_discovery()
  local shared = require("mdview.adapter.shared_relay")
  vim.fn.mkdir(vim.fs.dirname(shared.discovery_path()), "p")
  local port = M.free_port()
  _G.silent = assert(vim.uv.new_tcp())
  _G.silent_conns = {}
  assert(_G.silent:bind("127.0.0.1", port))
  assert(_G.silent:listen(8, function(err)
    if not err then
      local conn = assert(vim.uv.new_tcp())
      _G.silent:accept(conn)
      _G.silent_conns[#_G.silent_conns + 1] = conn
    end
  end))
  _G.stale = { protocol = 1, port = port, token = "sheet-stale-token", pid = dead_pid() }
  vim.fn.writefile({ vim.json.encode(_G.stale) }, shared.discovery_path())
  return true
end

---Close the silent listener of `_G.stale_discovery()` and what it accepted.
---@return boolean
function _G.close_silent()
  for _, conn in ipairs(_G.silent_conns or {}) do
    if not conn:is_closing() then
      conn:close()
    end
  end
  if _G.silent and not _G.silent:is_closing() then
    _G.silent:close()
  end
  return true
end

---Time every `discover()` of the shared relay (the real one runs): `_G.discover_ms` is the last one's milliseconds.
---@return boolean
function _G.time_discover()
  local shared = require("mdview.adapter.shared_relay")
  local real = shared.discover
  shared.discover = function(...)
    local t0 = vim.uv.hrtime()
    local info, why = real(...)
    _G.discover_ms = (vim.uv.hrtime() - t0) / 1e6
    _G.discover_why = why
    return info, why
  end
  return true
end

---Whether something accepts a connection on `port` of 127.0.0.1 (waits up to a second for the answer). Not
---`uv.kill(pid, 0)`: a killed detached relay stays a zombie of the editor on Linux and macOS, and a zombie has a pid.
---@param port integer
---@return boolean
function _G.listening(port)
  local tcp = assert(vim.uv.new_tcp())
  local result = nil
  tcp:connect("127.0.0.1", port, function(err)
    result = err == nil
  end)
  vim.wait(1000, function()
    return result ~= nil
  end, 10)
  tcp:close()
  return result == true
end

return M
