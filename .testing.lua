-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "mdview",
  -- Where the specs live (relative to this directory).
  roots = { "TESTS/lua", "TESTS/nvim" },
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "auto",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "lib.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  isolated = "file",
  -- "c" = child started from a -c command (v:vim_did_enter is 0, <cword> works),
  -- "l" = `nvim -l`.
  host = "c",
  -- Environment variables the specs read; a child editor inherits an allowlist only (never secrets).
  env_allow = { "LIB_NVIM_PATH" },
  -- The tier-3 cases (TESTS/lua/browser_e2e_spec.lua) each start a relay and a chromium in a node process of
  -- their own: 3 s on an idle machine, up to 10 s under load, which once hit the default 10 s case timeout.
  -- testing.nvim has no per-case timeout, so the project's limits leave them room (five such cases per file).
  timeouts = { case_ms = 30000, file_ms = 120000 },
  -- Guards (safety nets around each case, see testing.nvim's docs/GUARDS.md). The suite passes
  -- the fs, prompt, deprecation and scheduled-error guards cleanly, so those fail the case.
  guards = {
    fs = "error",
    prompt = "error",
    deprecation = "error",
    scheduled_error = "error",
    -- The process guard is on: the plugin shells out to curl (see guard_allow.spawn).
    process_net = "error",
    -- The suite leaves no state behind: the specs that open buffers, windows or tab pages put the
    -- editor back through TESTS/nvim/helpers/ui_reset.lua after each case, and the ones that attach
    -- the session autocmds or the :MDView command tear them down again. The one exception is
    -- :LibLogger, which lib.nvim's logger registers once per process (scheduled, from inside
    -- whichever case first creates a logger) and guards with its own idempotence flag: deleting
    -- the command would leave that flag lying. Highlight groups (syntax files), options, global
    -- variables (vim.g) and environment variables only ever warn; the specs put the ones they set
    -- back as well, except for the two kinds of process-wide state below.
    state = {
      mode = "error",
      ignore_usercmds = { "LibLogger" },
      -- Neovim's own syntax files (runtime/syntax/markdown.vim with the html, css, dtd,
      -- javascript, vb, xml and yaml syntax it pulls in, lua.vim and log.vim, loaded when a spec
      -- sets a buffer's filetype) define their highlight groups once per process;
      -- `:highlight clear` keeps the names, so a spec cannot take them back.
      ignore_highlights = {
        "markdown",
        "html",
        "css",
        "dtd",
        "javaScr",
        "vb",
        "xml",
        "yaml",
        "lua",
        "log",
        "Log",
      },
    },
  },
  -- What the specs may do on purpose.
  guard_allow = {
    -- ws_client pushes buffer content with `curl -X POST` to the local relay; the specs exercise
    -- that transport against a port without a server, so the spawn is the behavior under test.
    spawn = {
      "curl",
      -- browser_args_spec and server_args_spec make a fake executable with `chmod +x` (Unix only),
      -- which is how the specs create the "browser/server binary found on disk" fixture.
      "chmod",
      -- TESTS/nvim/sheets_spec.lua runs each test sheet in a child editor (testing.sheet).
      "nvim",
    },
  },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = { gate = true },
  ci = {
    -- Written as profiles because the relay has to be built before the suite: a step of its own would join `full`
    -- after it. Otherwise the derived pipeline (stylua, luacheck, suite, conformance) unchanged.
    profiles = {
      fast = { "stylua", "luacheck" },
      full = { "fast", "relay", "suite", "conformance", "workflow-in-sync" },
    },
    default = "full",
    steps = {
      -- The feature sheets of the preview (TESTS/sheets/_relay.lua) run the relay of this checkout. Without a build
      -- they are a reported skip, and CI counts the skip of a feature sheet as red. Node and Go come with the hosted
      -- images; the script finds the Go of the macOS image, which is not on PATH there.
      relay = { run = { "scripts/relay-build.sh" }, needs = { "node" }, timeout = "10m" },
      ["workflow-in-sync"] = { preset = "workflow-in-sync" },
    },
    -- The GitHub workflow, generated: `testing init --workflow=public --force` writes .github/workflows/ci.yml from
    -- this (testing.nvim docs/WORKFLOW-CI.md); the step workflow-in-sync keeps the two together. The Rust, Node, Go
    -- and browser checks and the release on a tag `v*` are hand-written in .github/workflows/native.yml: the
    -- generator has no Go/Rust setup and no tag trigger, and `testing ci land` waits for ci.yml only.
    workflow = {
      name = "mdview.nvim",
      layout = "hosted",
      -- the steps that depend on the platform: the windows and macOS legs run only these (the relay is built per leg)
      platform = { "relay", "suite", "conformance" },
      -- `testing ci land`: a check branch ci/** runs the hosted legs, main moves to a commit only once it is green there
      land = true,
    },
  },
}
