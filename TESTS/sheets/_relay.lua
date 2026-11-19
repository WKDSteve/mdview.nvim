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

vim.opt.shortmess:append("I")
vim.o.swapfile = false

---@type { msg: string, level: integer? }[]
_G.msgs = {}
vim.notify = function(msg, level)
  _G.msgs[#_G.msgs + 1] = { msg = tostring(msg), level = level }
end

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

---A port of 127.0.0.1 nobody listens on right now.
---@return integer
local function free_port()
  local tcp = assert(vim.uv.new_tcp())
  assert(tcp:bind("127.0.0.1", 0))
  local port = tcp:getsockname().port
  tcp:close()
  return port
end

---@param opts? { experimental?: table, shared?: boolean, browser?: table }
---@return boolean
function M.setup(opts)
  opts = opts or {}

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

  _G.port = free_port()

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
    shared_relay = { enabled = opts.shared == true },
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
    "--idle-timeout",
    "30",
  }, { text = true }, function(res)
    _G.other_exit = res.code
  end)
  return true
end

---Whether a process with this pid still runs.
---@param pid integer
---@return boolean
function _G.alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

return M
