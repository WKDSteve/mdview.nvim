-- `:MDView standalone --no-browser` (docs/standalone.md): a preview without Neovim behind it. The command probes the
-- relay of this checkout for --watch (one short run of the binary, asynchronous), then starts it detached on the file
-- on disk and says the pid and the URL. The relay outlives the editor by design ("Stop it by killing the pid"); the
-- sheet does that at the end. Setup and helpers: TESTS/sheets/_relay.lua.

return {
  id = "mdview.standalone",
  feature = "mdview.standalone",
  title = ":MDView standalone --no-browser starts a detached relay that watches the file and names its pid and URL",
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
    { expect = [[_G.open_doc()]], note = "a saved Markdown document is open" },
    { keys = ":MDView standalone --no-browser<CR>", note = "start a standalone preview of it" },
    {
      wait = [[_G.heard("[mdview] standalone preview started (pid ")]],
      timeout = 10000,
      note = "the relay was probed and started",
    },
    {
      lua = [[for _, m in ipairs(_G.msgs) do
        _G.standalone_pid = _G.standalone_pid or tonumber(m.msg:match("standalone preview started %(pid (%d+)%)"))
        _G.standalone_port = _G.standalone_port or tonumber(m.msg:match("Open: http://localhost:(%d+)/"))
      end]],
      note = "read the pid and the port from the message",
    },
    {
      expect = [[_G.standalone_pid ~= nil and _G.standalone_port ~= nil and _G.heard("doc.md")]],
      note = "it names the pid and the URL to open",
    },
    { wait = [[_G.listening(_G.standalone_port)]], timeout = 5000, note = "the relay serves the preview" },
    { lua = [[vim.uv.kill(_G.standalone_pid, "sigterm")]], note = "kill the pid, as the message says" },
    { wait = [[not _G.listening(_G.standalone_port)]], timeout = 5000, note = "the relay is gone" },
  },
  manual = {
    ":MDView standalone on a saved file opens a tab in the default browser; the tab follows saves of the file and "
      .. "stays open after :qa",
  },
}
