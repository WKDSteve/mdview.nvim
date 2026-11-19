-- TESTS/sheets/features.lua -- the functionalities of mdview.nvim that start a process (the relay, curl, the
-- browser, the OS opener), each with the feature sheet that checks it as its user meets it, or with `perf` saying
-- why `testing perf` does not measure it through a sheet of its own (testing.nvim docs/SHEETS.md, docs/PERF.md).
-- The sheets that run the real relay share TESTS/sheets/_relay.lua.
return {
  {
    id = "mdview.preview",
    title = "A browser preview of the buffer: the relay, a push per change, the browser->Neovim poll for write-backs",
    surface = {
      "command:MDView start",
      "command:MDView stop",
      "command:MDView edit",
      "config:sync_checkboxes",
      "config:sync_fields",
      "config:edit_blocks",
      "config:experimental.click_navigate",
      "config:experimental.reverse_scroll",
    },
    docs = "docs/FEATURES/PREVIEW.md",
  },
  {
    id = "mdview.shared-relay",
    title = "One relay and one tab for every Neovim instance: attach, heartbeat, detach",
    surface = { "config:shared_relay.enabled", "command:MDView start", "command:MDView stop" },
    docs = "docs/FEATURES/SHARED_RELAY.md",
  },
  {
    id = "mdview.standalone",
    title = "A preview without Neovim: a detached relay that watches the file on disk",
    surface = { "command:MDView standalone" },
    docs = "docs/standalone.md",
  },
  {
    id = "mdview.health",
    title = ":checkhealth mdview asks a running relay for /health",
    surface = { "command:checkhealth mdview" },
    docs = "docs/health.md",
  },
  {
    id = "mdview.diagnose",
    title = ":MDView diagnose writes a report with the relay's /health answer and opens it",
    surface = { "command:MDView diagnose" },
  },
  {
    id = "mdview.cursor-paragraph",
    title = "The cursor paragraph highlight, switched for every open tab (asks the relay for its tabs)",
    surface = { "command:MDView paragraph", "config:browser.cursor_paragraph", "config:browser.behavior" },
  },
  {
    id = "mdview.open-default-browser",
    title = 'The preview opens in the user\'s default browser through the OS opener (open_mode = "default")',
    surface = { "config:browser.open_mode", "config:browser.focus" },
    perf = 'manual:on Windows the opener is rundll32.exe (and a PowerShell for focus = "nvim"), which a stand-in '
      .. "cannot catch (testing.nvim/fakes-unter-windows-exe-namen-explorer-exe-rundll32-exe-und): a sheet would "
      .. "open a real browser",
  },
  {
    id = "mdview.install",
    title = "Without a local build the relay and the client bundle of the pinned release are downloaded",
    surface = { "config:install.version" },
    docs = "docs/installation.md",
    perf = "manual:downloads the release from GitHub (curl, tar): real network, and a sheet must never fetch it",
  },
}
