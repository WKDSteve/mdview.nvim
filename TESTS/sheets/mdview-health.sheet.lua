-- `:checkhealth mdview` with a preview running: the session section asks the relay GET /health (a short blocking
-- curl) and reports it healthy. Setup and helpers: TESTS/sheets/_relay.lua.

return {
  id = "mdview.health",
  feature = "mdview.health",
  title = ":checkhealth mdview during a preview asks the relay /health and reports it healthy",
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
    { input = ":checkhealth mdview<CR>", note = "run the health check" },
    {
      wait = [[vim.bo.filetype == "checkhealth" and _G.buf_has("mdview.nvim: session")]],
      timeout = 15000,
      note = "the report is open with its session section",
    },
    {
      expect = [[_G.buf_has("relay running on port " .. vim.g.mdview_server_port .. " and healthy (GET /health = ok)")]],
      note = "the running relay answered /health",
    },
    { keys = ":tabclose<CR>", note = "close the report" },
    { keys = ":MDView stop<CR>", note = "stop the preview" },
    { wait = [[require("mdview.core.state").get_server() == nil]], timeout = 5000, note = "the session is gone" },
  },
}
