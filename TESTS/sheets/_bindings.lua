-- TESTS/sheets/_bindings.lua -- the setup of the binding sheets (mdview-bindings-*.sheet.lua). Not a sheet
-- (`testing.sheet` only reads *.sheet.lua); the first step of such a sheet runs it with `dofile`, the child's cwd is
-- the project root. The directory is in the spec's @cache-inputs.
--
-- Covers the mdview.nvim items of the bindings runtime checklist of the nvim config
-- (docs/ROADMAP/Final_Checks/BINDINGS-RUNTIME-CHECKLIST.md, section ":MDView"): every subcommand is typed on the
-- command line as a person types it, and the sheet reads what it did -- the message it gave, the buffer or tab it
-- opened, the file it wrote, and what it handed to the relay or the browser.
--
-- The configuration mirrors the one of the nvim config (lua/plugins/personal/specs/view.lua): browser.highlighter
-- "hljs", focus "nvim", cursor_marker "caret" and the three experimental switches. Two things differ, both so that
-- nothing leaves the sandbox: the dependency popup is off (lib.nvim.deps would open a float on the first start) and
-- the browser is opened in "isolated" mode through `browser_cmd = "mdview-sheet-browser"`, a recording stand-in the
-- sheet puts first on the PATH (`fakes`); the default mode would hand the URL to the OS opener (rundll32, open,
-- xdg-open), which a stand-in cannot catch on Windows. The stand-in exits at once, so `stop_on_browser_exit` is off.
--
-- The relay is not started: a sheet has neither the Go binary nor a browser page. What the commands send to it is
-- recorded instead, one level below the code under test (mdview.adapter.ws_client, the HTTP transport to the
-- relay): `_G.sent` lists every send_control / send_content / ... call. `_G.session(true)` puts a stand-in into the
-- session state (a server handle and the attached flag), as a running `:MDView start` leaves it, so the commands
-- that act on a live preview take that branch; `_G.session(false)` takes it away again.
--
-- Messages: vim.notify is a recorder (`_G.msgs`), so a long message raises no hit-enter prompt that would hold the
-- next key; `_G.said(text)` reads the last one, `_G.text()` all of them since the last read.

-- luacheck: globals vim
---@diagnostic disable: duplicate-set-field

vim.opt.shortmess:append("I")
vim.o.swapfile = false
vim.g.mapleader = " "

---@type { msg: string, level: integer? }[]
_G.msgs = {}
vim.notify = function(msg, level)
  _G.msgs[#_G.msgs + 1] = { msg = tostring(msg), level = level }
end

---Every message since the last read, joined by newlines; reading clears them.
---@return string
function _G.text()
  local out = {}
  for _, m in ipairs(_G.msgs) do
    out[#out + 1] = m.msg
  end
  _G.msgs = {}
  return table.concat(out, "\n")
end

---Whether the last message contains `text` (plain); `level` (a vim.log.levels name) must match when given.
---Clears the messages.
---@param text string
---@param level? string
---@return boolean
function _G.said(text, level)
  local last = _G.msgs[#_G.msgs]
  _G.msgs = {}
  if not last or not last.msg:find(text, 1, true) then
    return false
  end
  return level == nil or last.level == vim.log.levels[level]
end

-- The fixture: a Markdown file with two headings in a temp dir (realpath: on macOS tempname() is below /var,
-- a link to /private/var, and mdview keys a document by its resolved path).
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = vim.fs.normalize(vim.uv.fs_realpath(tmp) or tmp)
_G.fixture = tmp
vim.g.mdview_sheet_fixture = tmp -- for <C-r>= on the command line
vim.fn.writefile({ "# Alpha", "", "first", "", "## Beta", "", "second" }, tmp .. "/doc.md")

require("mdview").setup({
  deps_popup = false,
  browser = {
    highlighter = "hljs",
    focus = "nvim",
    cursor_marker = "caret",
    open_mode = "isolated",
    browser_cmd = "mdview-sheet-browser",
    -- The stand-in exits at once; a real browser stays, so its exit must not end the session.
    stop_on_browser_exit = false,
  },
  experimental = {
    line_diff = true,
    click_navigate = true,
    reverse_scroll = true,
  },
})

-- The relay transport: every send is recorded and answers as a healthy relay does.
local ws_client = require("mdview.adapter.ws_client")
---@type { fn: string, args: any[] }[]
_G.sent = {}
for name, fn in pairs(ws_client) do
  if type(fn) == "function" and name:match("^send_") then
    ws_client[name] = function(...)
      _G.sent[#_G.sent + 1] = { fn = name, args = { ... } }
      return true
    end
  end
end
ws_client.tab_rooms = function(cb)
  if cb then
    cb({})
  end
end
ws_client.wait_ready = function(cb)
  if cb then
    cb(true)
  end
end

---The control fields sent to the relay since the last read, merged in order; reading clears the record.
---@return table fields
function _G.control()
  local fields = {}
  for _, s in ipairs(_G.sent) do
    if s.fn == "send_control" then
      for k, v in pairs(vim.json.decode(s.args[2])) do
        fields[k] = v
      end
    end
  end
  _G.sent = {}
  return fields
end

local state = require("mdview.core.state")

---Put a stand-in session into the state (on) or take it away (off).
---@param on boolean
---@return boolean
function _G.session(on)
  if on then
    state.set_server({ sheet = true })
    state.set_attached(true)
  else
    state.set_attached(false)
    state.clear_server()
  end
  return true
end

---Open the fixture document in the current window.
---@return boolean
function _G.open_doc()
  vim.cmd.edit(vim.fn.fnameescape(tmp .. "/doc.md"))
  return vim.bo.filetype == "markdown"
end

---The lines of the buffer named `name` (exact), or nil.
---@param name string
---@return string[]?
function _G.lines_of(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
  end
  return nil
end

---The content of a file, or "" when it does not exist.
---@param path string
---@return string
function _G.file(path)
  if vim.fn.filereadable(path) == 0 then
    return ""
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

---The calls of the browser stand-in.
---@return { argv: string[] }[]
function _G.browser()
  return require("testing.fake_programs").read(vim.env.TESTING_FAKES, "mdview-sheet-browser")
end

return {}
