---@module 'tests.nvim.standalone_run_spec'
-- The whole run of :MDView standalone (mdview.bindings.usrcmds.standalone.run): which relay binary and
-- bundle it takes, the capability probe, the arguments the detached relay is started with, and what the user
-- is told. vim.system (the probe), the spawn and the binary/bundle lookups are stubbed -- no process starts.
-- The helpers resolve_web_root / warn_mismatch_once have their own cases in server_args_spec.lua.

---@diagnostic disable: undefined-global

local standalone = require("mdview.bindings.usrcmds.standalone")
local detached = require("mdview.adapter.detached")
local server_args = require("mdview.adapter.server_args")
local display = require("mdview.core.display")
local config = require("mdview.config")

local TARGET = "/work/notes/notes.md"
local USAGE_WATCH = "Usage:\n  -watch string\n  -token string\n"
local USAGE_WATCH_EDIT = USAGE_WATCH .. "  -edit\n"

local saved, spawned, probes, messages, usage_for_probe
local binary_n = 0

---@return string # a binary path no earlier case used (the probe verdict is memoised per path)
local function fresh_binary()
  binary_n = binary_n + 1
  return ("/fake/relay-%d/mdview-server"):format(binary_n)
end

---Replace tbl[key] for one case; after_each puts the original back.
local function stub(tbl, key, value)
  saved[#saved + 1] = { tbl, key, tbl[key] }
  tbl[key] = value
end

local function messages_matching(level, needle)
  for _, m in ipairs(messages) do
    if (level == nil or m.level == level) and m.msg:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- Run `standalone.run` and wait until it either spawned or reported.
local function run(file, no_browser)
  standalone.run(file, no_browser)
  vim.wait(1000, function()
    return #spawned > 0 or #messages > 0
  end, 10)
end

before_each(function()
  saved, spawned, probes, messages = {}, {}, {}, {}
  usage_for_probe = USAGE_WATCH

  stub(vim, "notify", function(msg, level)
    messages[#messages + 1] = { msg = tostring(msg), level = level }
  end)
  stub(display, "active", function()
    return false
  end)
  stub(detached, "resolve_target", function()
    return TARGET
  end)
  stub(detached, "spawn", function(bin, args, cwd)
    spawned[#spawned + 1] = { bin = bin, args = args, cwd = cwd }
    return 4242
  end)
  local bin = fresh_binary()
  stub(server_args, "local_built_binary", function()
    return bin
  end)
  stub(server_args, "resolve_web_root", function()
    return "/fake/web", nil, "local"
  end)
  stub(server_args, "warn_mismatch_once", function() end)
  stub(vim, "system", function(cmd, _, on_exit)
    probes[#probes + 1] = cmd
    on_exit({ code = 2, stdout = "", stderr = usage_for_probe })
  end)

  local defaults = config.defaults
  stub(defaults, "server_port", 43219)
  stub(defaults, "edit_blocks", false)
  stub(defaults, "standalone", {})
end)

after_each(function()
  for i = #saved, 1, -1 do
    local tbl, key, old = unpack(saved[i])
    tbl[key] = old
  end
end)

describe("standalone.run", function()
  it("probes the binary, then starts it detached in the file's folder with --watch and a port offset by 100", function()
    run(nil, false)
    assert.are.equal(1, #probes)
    assert.are.equal("--mdview-capability-probe", probes[1][2])
    assert.are.equal(1, #spawned)
    local a = spawned[1].args
    assert.are.equal("--watch", a[1])
    assert.are.equal(TARGET, a[2])
    assert.are.equal("--token", a[3])
    assert.is_truthy(a[4] and #a[4] > 0)
    assert.are.same({ "--web-root", "/fake/web", "--port", "43319", "--theme", "github", "--hl", "hljs" }, { unpack(a, 5, 12) })
    assert.are.equal(12, #a) -- no --open=false, no --edit
    assert.are.equal("/work/notes", spawned[1].cwd)
    assert.is_true(messages_matching(vim.log.levels.INFO, "standalone preview started (pid 4242)"))
  end)

  it("--no-browser passes --open=false and prints the URL, the only way into the preview", function()
    run(nil, true)
    local a = spawned[1].args
    assert.are.equal("--open=false", a[#a])
    assert.is_true(messages_matching(vim.log.levels.INFO, "http://localhost:43319/?key="))
    assert.is_true(messages_matching(vim.log.levels.INFO, "&token="))
  end)

  it("a relay without --watch is refused with the version hint, nothing is spawned", function()
    usage_for_probe = "Usage:\n  -port int\n"
    run(nil, false)
    assert.are.equal(0, #spawned)
    assert.is_true(messages_matching(vim.log.levels.ERROR, "no --watch support"))
  end)

  it("edit_blocks passes --edit to a relay that lists the flag", function()
    config.defaults.edit_blocks = true
    usage_for_probe = USAGE_WATCH_EDIT
    run(nil, false)
    local a = spawned[1].args
    assert.are.equal("--edit", a[#a])
  end)

  it("edit_blocks with a relay that lacks --edit warns and starts without it", function()
    config.defaults.edit_blocks = true
    run(nil, false)
    assert.are.equal(1, #spawned)
    assert.are.equal(12, #spawned[1].args)
    assert.is_true(messages_matching(vim.log.levels.WARN, "no --edit support"))
  end)

  it("refuses when a display language or transform is active, before probing anything", function()
    display.active = function()
      return true
    end
    run(nil, false)
    assert.are.equal(0, #probes)
    assert.are.equal(0, #spawned)
    assert.is_true(messages_matching(vim.log.levels.ERROR, "display_lang"))
  end)

  it("reports a target it cannot resolve", function()
    detached.resolve_target = function()
      return nil, "no file"
    end
    run(nil, false)
    assert.are.equal(0, #spawned)
    assert.is_true(messages_matching(vim.log.levels.ERROR, "standalone: no file"))
  end)

  it("reports a missing bundle instead of starting a relay that cannot serve", function()
    server_args.resolve_web_root = function()
      return nil, "no bundle found"
    end
    run(nil, false)
    assert.are.equal(0, #spawned)
    assert.is_true(messages_matching(vim.log.levels.ERROR, "no bundle found"))
  end)

  it("an unusable standalone.binary_path is an error naming the path", function()
    config.defaults.standalone = { binary_path = "/nope/relay" }
    stub(server_args, "spawnable", function()
      return nil
    end)
    run(nil, false)
    assert.are.equal(0, #spawned)
    assert.is_true(messages_matching(vim.log.levels.ERROR, "standalone.binary_path is not spawnable"))
  end)

  it("a spawn failure is reported", function()
    detached.spawn = function()
      return nil, "ENOENT"
    end
    run(nil, false)
    assert.is_true(messages_matching(vim.log.levels.ERROR, "failed to spawn relay: ENOENT"))
  end)
end)
