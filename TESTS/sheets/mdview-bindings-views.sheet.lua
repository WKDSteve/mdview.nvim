-- The :MDView commands of the bindings checklist of the nvim config that open something (BINDINGS-RUNTIME-CHECKLIST.md,
-- section ":MDView"): the log ring and the relay log in a scratch buffer, the export files, the breadcrumbs, the
-- diagnostics report, the in-Neovim tab preview, and -- with a stand-in session -- :MDView open and :MDView write,
-- which hand the URL to the browser and the write mode to the relay. Setup: TESTS/sheets/_bindings.lua. The browser
-- is a recording stand-in (`fakes`); what the page shows is for a person (`manual`).

local steps = {
  {
    lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_bindings.lua")]],
    note = "mdview.setup as in the nvim config, vim.notify and the relay transport recorders",
  },
  { expect = [[_G.open_doc()]], note = "a Markdown document is open" },
}

local function add(step)
  steps[#steps + 1] = step
end

---Type `:MDView <line>` and check what it did.
local function cmd(line, expect, note)
  add({ keys = ":MDView " .. line .. "<CR>", note = ":MDView " .. line .. ": " .. note })
  add({ expect = expect, note = ":MDView " .. line .. " " .. note })
end

-- The log ring: one record per level, each with its own tag, as the plugin writes them.
add({
  lua = [[local log = require("mdview.log").instance
    log.trace("sheet-trace"); log.debug("sheet-debug"); log.info("sheet-info")
    log.warn("sheet-warn"); log.error("sheet-error")]],
  note = "five log records, one per level",
})

-- A sheet is read with an empty environment (no ipairs, no table library): plain loops and concatenation.
local LEVELS = { "trace", "debug", "info", "warn", "error" }

---The log scratch is the current window and shows the tags of the levels from `from` (an index into LEVELS) up,
---none below it; the window is closed after.
local function ring(line, from, note)
  local expr = [[vim.api.nvim_buf_get_name(0) == "mdview://log"]]
  for i = 1, #LEVELS do
    local found = [[(table.concat(_G.lines_of("mdview://log"), "\n"):find("sheet-]] .. LEVELS[i] .. [[", 1, true))]]
    expr = expr .. " and " .. (i >= from and found or "not " .. found)
  end
  cmd(line, expr, note)
  add({ keys = ":close<CR>", note = "close the log window" })
end

ring("log", 1, "shows the whole ring in a scratch window")
ring("log trace", 1, "shows TRACE and above")
ring("log debug", 2, "shows DEBUG and above")
ring("log info", 3, "shows INFO and above")
ring("log warn", 4, "shows WARN and above")
ring("log error", 5, "shows ERROR only")

cmd(
  "log export",
  [[_G.said("[mdview] log written to " .. vim.fn.stdpath("log") .. "/mdview-log.txt", "INFO")
    and _G.file(vim.fn.stdpath("log") .. "/mdview-log.txt"):find("ERROR  sheet-error", 1, true) ~= nil]],
  "writes the ring to the default file below stdpath('log')"
)

-- The relay log: lines the relay printed, among them a browser-side diagnostic.
add({
  lua = [[require("mdview.adapter.log").append("relay: listening on 127.0.0.1:43219")
    require("mdview.adapter.log").append("[client] sheet: page rendered")]],
  note = "two lines of relay stdout",
})
-- The log buffer is shown from a vim.schedule callback: wait for it.
add({ keys = ":MDView weblogs<CR>", note = ":MDView weblogs: shows the relay log" })
add({
  wait = [[vim.api.nvim_buf_get_name(0) == "mdview://logs"
    and vim.deep_equal(vim.api.nvim_buf_get_lines(0, -3, -1, false),
      { "relay: listening on 127.0.0.1:43219", "[client] sheet: page rendered" })]],
  note = ":MDView weblogs shows the relay's captured stdout with the [client] line",
})
add({ keys = ":buffer #<CR>", note = "back to the document" })
add({ expect = [[vim.api.nvim_buf_get_name(0):find("doc.md", 1, true) ~= nil]], note = "the document is current again" })

-- Breadcrumbs: recorded as the CursorMoved autocmd of a session records them.
cmd("breadcrumbs clear", [[_G.said("[mdview] breadcrumbs cleared", "INFO")]], "starts from nothing")
add({
  lua = [[local crumbs = require("mdview.core.breadcrumbs")
    vim.api.nvim_win_set_cursor(0, { 3, 0 }); crumbs.record(vim.api.nvim_get_current_buf())
    vim.api.nvim_win_set_cursor(0, { 7, 0 }); crumbs.record(vim.api.nvim_get_current_buf())]],
  note = "the cursor visits Alpha, then Beta",
})
cmd(
  "breadcrumbs",
  [[vim.api.nvim_buf_get_name(0) == "mdview://breadcrumbs"
    and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("# Alpha", 1, true)
    and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("## Beta", 1, true)]],
  "shows the document and both headings"
)
add({ keys = ":close<CR>", note = "close the breadcrumbs window" })
cmd(
  "breadcrumbs export",
  [[_G.said("[mdview] breadcrumbs written to " .. vim.fn.stdpath("log") .. "/mdview-breadcrumbs.md", "INFO")
    and _G.file(vim.fn.stdpath("log") .. "/mdview-breadcrumbs.md"):find("## Beta", 1, true) ~= nil]],
  "writes the outline below stdpath('log')"
)
cmd("breadcrumbs clear", [[_G.said("[mdview] breadcrumbs cleared", "INFO")]], "discards them")
cmd(
  "breadcrumbs",
  [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("no breadcrumbs recorded yet", 1, true)]],
  "then shows none"
)
add({ keys = ":close<CR>", note = "close the breadcrumbs window" })

-- The tab preview inside Neovim: no relay needed.
cmd(
  "preview-tab",
  [[#vim.api.nvim_list_tabpages() == 2 and vim.api.nvim_buf_get_name(0):find("[mdview preview] doc.md", 1, true)
    and vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, 1, false), { "# Alpha" })]],
  "opens a tab with the rendered document"
)
add({ keys = ":tabprevious<CR>", note = "back to the source tab" })
cmd("preview-tab", [[#vim.api.nvim_list_tabpages() == 1]], "on the source toggles the tab preview off")

cmd(
  "diagnose",
  [[_G.said("[mdview] diagnostics written to " .. vim.fn.stdpath("log") .. "/mdview-diagnostics.txt", "INFO")
    and #vim.api.nvim_list_tabpages() == 2
    and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("mdview.nvim diagnostics", 1, true)
    and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("== Environment ==", 1, true)]],
  "writes the report and opens it in a tab"
)
add({ keys = ":tabclose<CR>", note = "close the report" })

-- Without a session :MDView open has nothing to open.
cmd("open", [[_G.said("[mdview] no mdview session running", "WARN") and #_G.browser() == 0]], "needs a session")

-- With a stand-in session.
add({ lua = [[_G.session(true)]], note = "a session runs (stand-in)" })
add({ keys = ":MDView open<CR>", note = ":MDView open: opens a browser tab" })
add({ wait = [[#_G.browser() == 1]], note = ":MDView open starts the browser (the stand-in records it)" })
add({
  expect = [[_G.said("[mdview] opened preview: http://localhost:43219/", "INFO")
    and table.concat(_G.browser()[1].argv, " "):find("http://localhost:43219/", 1, true) ~= nil]],
  note = ":MDView open hands the session's URL (the relay port of the config) to the browser",
})
cmd(
  "write",
  [[require("mdview.bindings.usrcmds.write").is_on()
    and vim.deep_equal(_G.control(), { cursor = "caret", editBlocks = true })
    and _G.said("[mdview] write mode: on (caret + block editing)", "INFO")]],
  "turns caret and block editing on together"
)
cmd(
  "write",
  [[not require("mdview.bindings.usrcmds.write").is_on() and _G.control().editBlocks == false
    and _G.said("[mdview] write mode: off", "INFO")]],
  "and off again"
)
add({ lua = [[_G.session(false); _G.sent = {}]], note = "the session ends" })
add({ expect = [[_G.text() == ""]], note = "no message is left that no step asked for" })

return {
  id = "mdview.bindings-views",
  title = "The :MDView commands of the nvim config open the log, breadcrumbs, report, tab preview and browser tab",
  task = "mdview.nvim/bindings-checkliste-im-echten-browser-abnehmen",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  -- `cursor` and `edit`: on Windows the browser stand-in is a .cmd file, and cmd.exe runs every `&<key>=<value>` of
  -- the preview URL as a command of its own (`&cursor=caret` started the Cursor editor, `&edit=1` would start
  -- edit.exe); stand-ins of those names catch them until testing.nvim's stand-in keeps an argument whole.
  fakes = { "mdview-sheet-browser", "cursor", "edit" },
  steps = steps,
  manual = {
    "In the real config: :MDView start opens the preview of the current buffer in the default browser, :MDView open opens a second tab on the same session, :MDView weblogs then shows the relay's real stdout",
    ":MDView standalone on a saved file: the preview stays open after :qa and follows saves of the file",
    ":MDView write without a session starts the preview; in the browser a click on a block opens its editor and the caret follows the Neovim cursor",
  },
}
