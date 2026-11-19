-- `:MDView paragraph on` with a tab per document (`browser.behavior = "new_tab"`): the switch concerns every open tab,
-- so the command asks the relay which rooms have a tab (GET /attach, asynchronous curl) and sends the change to those.
-- No browser is connected in the sheet, so the relay names no tab and nothing is sent; the message says the highlight
-- is on. Setup and helpers: TESTS/sheets/_relay.lua.

return {
  id = "mdview.paragraph-tabs",
  feature = "mdview.cursor-paragraph",
  title = ":MDView paragraph on with a tab per document asks the relay for its tabs and switches the highlight on",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
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
        browser = { behavior = "new_tab", browser_autostart = false },
      })]],
      note = "mdview.setup with a tab per document, no browser",
    },
    { expect = [[_G.open_doc()]], note = "a Markdown document is open" },
    { keys = ":MDView start<CR>", note = "start the preview" },
    { wait = [[_G.relay_ready()]], timeout = 15000, note = "the relay is up" },
    { lua = [[_G.msgs = {}]] },
    { keys = ":MDView paragraph on<CR>", note = "switch the cursor paragraph highlight on" },
    {
      wait = [[_G.heard("[mdview] cursor paragraph: highlighted in the preview")]],
      timeout = 5000,
      note = "it says the highlight is on",
    },
    { expect = [[require("mdview.config.browser").defaults.cursor_paragraph == true]], note = "and remembers it" },
    { lua = [[_G.t0 = vim.uv.now()]] },
    { wait = [[vim.uv.now() - _G.t0 >= 500]], timeout = 2000, note = "the answer of the relay came in" },
    { keys = ":MDView stop<CR>", note = "stop the preview" },
    { wait = [[require("mdview.core.state").get_server() == nil]], timeout = 5000, note = "the session is gone" },
  },
}
