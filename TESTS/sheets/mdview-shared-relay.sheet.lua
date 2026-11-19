-- One relay for every Neovim instance (`shared_relay.enabled`, docs/FEATURES/SHARED_RELAY.md): another instance runs
-- the shared relay (the sheet starts it as that instance's first `:MDView start` leaves it: `--shared`, the discovery
-- file of this sandbox), `:MDView start` here finds it, checks it with a short blocking GET /attach and attaches
-- instead of spawning a second relay; while attached the heartbeat asks the relay every two seconds; `:MDView stop`
-- detaches, and the relay, left without an instance, ends. Setup and helpers: TESTS/sheets/_relay.lua.

return {
  id = "mdview.shared-relay",
  feature = "mdview.shared-relay",
  title = ":MDView start attaches to the shared relay of another instance, :MDView stop detaches and the relay ends",
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
        shared = true,
        browser = { browser_autostart = false },
      })]],
      note = "mdview.setup with the shared relay on, no browser",
    },
    { expect = [[_G.open_doc()]], note = "a Markdown document is open" },
    { lua = [[_G.other_instance()]], note = "another instance runs the shared relay" },
    {
      wait = [[require("mdview.adapter.shared_relay").read_discovery() ~= nil]],
      timeout = 10000,
      note = "it advertises itself in the discovery file",
    },
    { keys = ":MDView start<CR>", note = "start the preview here" },
    {
      wait = [[require("mdview.adapter.shared_relay").is_attached() and _G.relay_ready()]],
      timeout = 10000,
      note = "attached to the running relay",
    },
    {
      expect = [[require("mdview.core.state").get_server().shared == true
        and vim.g.mdview_server_port == require("mdview.adapter.shared_relay").read_discovery().port]],
      note = "no relay of its own: the session is the shared one, on its port",
    },
    { keys = "Go- [ ] third task<Esc>", note = "type a third task (pushed to the shared relay)" },
    { lua = [[_G.t0 = vim.uv.now()]] },
    {
      wait = [[vim.uv.now() - _G.t0 >= 2500]],
      timeout = 5000,
      note = "two and a half idle seconds: one heartbeat and the poll",
    },
    { expect = [[_G.other_exit == nil]], note = "the shared relay still runs" },
    { keys = ":MDView stop<CR>", note = "stop the preview here" },
    {
      wait = [[_G.other_exit ~= nil]],
      timeout = 10000,
      note = "detached: the relay, left without an instance, ends",
    },
    { expect = [[not require("mdview.adapter.shared_relay").is_attached()]], note = "and this instance let go" },
  },
  manual = {
    "Two Neovim instances with shared_relay.enabled: the second :MDView start opens no second tab; "
      .. "focusing an instance makes the tab show its document; quitting both closes the tab",
  },
}
