-- The preview as its user meets it: a Markdown file is open, `:MDView start` starts the relay of this checkout and
-- opens the browser (a recording stand-in), typing reaches the relay, a checkbox ticked in the browser comes back into
-- the buffer through the browser->Neovim poll, `:MDView edit on` adds the block-edit queue to that poll, and
-- `:MDView stop` ends the relay. Setup and helpers: TESTS/sheets/_relay.lua.
--
-- For `testing perf` this is the sheet of the steady cost of an open preview: the idle step lets the poll run for
-- two seconds with the switches of the nvim config (click_navigate and reverse_scroll on), so the report shows how
-- many curl processes an open preview starts while nothing happens (task
-- mdview.nvim/inbound-poll-buendeln-statt-mehrere-curl-je-tick).

return {
  id = "mdview.preview",
  feature = "mdview.preview",
  title = ":MDView start previews the buffer through the relay, a ticked checkbox comes back, :MDView stop ends it",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  -- `cursor` and `edit`: on Windows the browser stand-in is a .cmd file, and cmd.exe runs every `&<key>=<value>` of
  -- the preview URL as a command of its own (`&cursor=caret` started the Cursor editor, `&edit=1` would start
  -- edit.exe); stand-ins of those names catch them until testing.nvim's stand-in keeps an argument whole.
  fakes = { "mdview-sheet-browser", "cursor", "edit" },
  requires = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_relay.lua").relay_binary() ~= nil]],
      reason = "the relay of this checkout is not built (node scripts/build-go.mjs)",
    },
  },
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_relay.lua").setup({
        experimental = { line_diff = true, click_navigate = true, reverse_scroll = true },
      })]],
      note = "mdview.setup as in the nvim config, on a free port, the relay of this checkout",
    },
    { expect = [[_G.open_doc()]], note = "a Markdown document with two tasks is open" },
    { keys = ":MDView start<CR>", note = "start the preview" },
    { wait = [[_G.relay_ready()]], timeout = 15000, note = "the relay is up and answered /health" },
    { wait = [[#_G.browser() == 1]], timeout = 5000, note = "the browser was opened once" },
    {
      expect = [[table.concat(_G.browser()[1].argv, " "):find("http://localhost:" .. vim.g.mdview_server_port .. "/", 1, true)
        ~= nil]],
      note = "with the URL of the relay's port",
    },
    { keys = "Go- [ ] third task<Esc>", note = "type a third task" },
    { lua = [[_G.t0 = vim.uv.now()]] },
    {
      wait = [[vim.uv.now() - _G.t0 >= 2000]],
      timeout = 5000,
      note = "two idle seconds with the preview open: the poll asks the relay every 250 ms",
    },
    { lua = [[_G.browser_tick(3)]], note = "the browser ticks the first task" },
    { wait = [[_G.tick_result == "204"]], timeout = 5000, note = "the relay took the tick" },
    {
      wait = [[vim.api.nvim_buf_get_lines(0, 2, 3, false)[1] == "- [x] first task"]],
      timeout = 5000,
      note = "the poll brought the tick into the buffer",
    },
    { keys = ":MDView edit on<CR>", note = "switch block editing on for the running session" },
    { lua = [[_G.t0 = vim.uv.now()]] },
    { wait = [[vim.uv.now() - _G.t0 >= 1000]], timeout = 3000, note = "one idle second with the edit queue polled" },
    { keys = ":MDView stop<CR>", note = "stop the preview" },
    {
      wait = [[require("mdview.core.state").get_server() == nil]],
      timeout = 5000,
      note = "the session is gone",
    },
    { expect = [[_G.heard("[mdview] started")]], note = "start said so" },
  },
  judge = { "the preview shows the document, the third task appears while typing, the tick is drawn" },
  manual = {
    "With a real browser (no browser_cmd): :MDView start opens a tab that shows the document and follows typing; "
      .. "ticking a checkbox in the tab ticks it in the buffer within a quarter second; :MDView stop closes the tab",
  },
}
