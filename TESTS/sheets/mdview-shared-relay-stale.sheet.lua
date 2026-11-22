-- A stale discovery file (`shared_relay.enabled`, docs/FEATURES/SHARED_RELAY.md): the shared relay of another
-- instance crashed and left its file behind -- its pid is gone, and another program now holds its port and never
-- answers. `:MDView start` must not wait on that port (the blocking GET /attach held the editor for its whole limit of
-- 1 s): it sees the pid is gone, spawns a shared relay of its own, which rewrites the file, and `:MDView stop` ends
-- it again. Setup and helpers: TESTS/sheets/_relay.lua.

return {
  id = "mdview.shared-relay-stale",
  feature = "mdview.shared-relay",
  title = ":MDView start with a stale discovery file spawns its own shared relay without waiting on the dead port",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  fakes = { "mdview-sheet-browser" },
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
        idle_timeout_s = 3,
        browser = { browser_autostart = false },
      })]],
      note = "mdview.setup with the shared relay on, no browser",
    },
    { expect = [[_G.open_doc()]], note = "a Markdown document is open" },
    {
      lua = [[_G.stale_discovery()]],
      note = "a crashed shared relay left its discovery file: dead pid, a port that never answers",
    },
    { lua = [[_G.time_discover()]], note = "time the discovery of :MDView start" },
    { keys = ":MDView start<CR>", note = "start the preview here" },
    {
      wait = [[require("mdview.adapter.shared_relay").is_attached() and _G.relay_ready()]],
      timeout = 15000,
      note = "a shared relay of its own is up",
    },
    {
      expect = [[_G.discover_ms ~= nil and _G.discover_ms < 250]],
      note = "the stale file cost the start no wait on the dead port (was ~1000 ms on Windows)",
    },
    {
      expect = [[require("mdview.core.state").get_server().shared ~= true
        and require("mdview.adapter.shared_relay").may_push()]],
      note = "it spawned the relay (its own process) and owns the tab",
    },
    {
      wait = [[(function()
        local d = require("mdview.adapter.shared_relay").read_discovery()
        return d ~= nil and d.port == vim.g.mdview_server_port and d.port ~= _G.stale.port
      end)()]],
      timeout = 10000,
      note = "the new relay replaced the stale discovery file",
    },
    { keys = ":MDView stop<CR>", note = "stop the preview here" },
    {
      wait = [[vim.fn.filereadable(require("mdview.adapter.shared_relay").discovery_path()) == 0]],
      timeout = 15000,
      note = "detached: the relay, left without an instance, ends and removes its file (idle timeout 3 s)",
    },
    { lua = [[_G.close_silent()]], note = "close the program on the old port" },
  },
  manual = {
    "Kill the shared relay (Task Manager / kill -9), leave its relay.json behind, then :MDView start in a new "
      .. "instance: no pause, a new tab",
  },
}
