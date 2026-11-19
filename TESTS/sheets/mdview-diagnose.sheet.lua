-- `:MDView diagnose <path>` with a preview running: the report asks the relay GET /health (a short blocking curl),
-- is written to the path and opened in a tab, ready to hand over. Setup and helpers: TESTS/sheets/_relay.lua.

return {
  id = "mdview.diagnose",
  feature = "mdview.diagnose",
  title = ":MDView diagnose during a preview writes the report with the relay's /health answer and opens it",
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
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_relay.lua").setup({ browser = { browser_autostart = false } })]],
      note = "mdview.setup on a free port, the relay of this checkout",
    },
    { expect = [[_G.open_doc()]], note = "a Markdown document is open" },
    { keys = ":MDView start<CR>", note = "start the preview" },
    { wait = [[_G.relay_ready()]], timeout = 15000, note = "the relay is up" },
    {
      keys = ":MDView diagnose <C-r>=g:mdview_sheet_fixture<CR>/diagnose.txt<CR>",
      note = "write the diagnostics report next to the document",
    },
    {
      wait = [[vim.fn.filereadable(_G.fixture .. "/diagnose.txt") == 1 and _G.buf_has("GET /health")]],
      timeout = 10000,
      note = "the report is written and open",
    },
    {
      expect = [[vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(l)
        return l:match("^%s*GET /health:%s+ok%s*$") ~= nil
      end)]],
      note = "with the relay's /health answer",
    },
    { expect = [[_G.heard("[mdview] diagnostics written to ")]], note = "and says where it is" },
    { keys = ":tabclose<CR>", note = "close the report" },
    { keys = ":MDView stop<CR>", note = "stop the preview" },
    { wait = [[require("mdview.core.state").get_server() == nil]], timeout = 5000, note = "the session is gone" },
  },
}
