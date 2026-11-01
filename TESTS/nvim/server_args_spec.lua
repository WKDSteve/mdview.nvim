---@module 'tests.nvim.server_args_spec'
-- Verifies mdview.adapter.server_args' notion of "a path uv.spawn() can start",
-- which is not the same as vim.fn.executable(). libuv resolves a command with
-- no extension by appending .com/.exe/.bat/.cmd and never tries the bare name,
-- so on Windows an extension-less relay binary passes executable() and then
-- spawns as ENOENT — the failure this guards against. A name that already
-- carries an extension libuv tries verbatim instead, which executable() does
-- not model either: see the 'shell' case at the bottom.

---@diagnostic disable: undefined-global

local server_args = require("mdview.adapter.server_args")

local windows = vim.fn.has("win32") == 1

--- Run `fn(dir)` with a fresh temp directory, removed again afterwards.
---@param fn fun(dir: string)
---@return nil
local function with_tempdir(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local ok, err = pcall(fn, dir)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end

--- Create an empty file and make it executable where that means anything.
---@param path string
---@return string path
local function touch_executable(path)
  -- Not assert(io.open(...)): the harness's assert() is a bare guard and
  -- returns nothing, so wrapping the handle in it throws the handle away.
  local f = io.open(path, "w")
  assert(f, "could not create " .. path)
  f:write("")
  f:close()
  if not windows then
    os.execute(("chmod +x %q"):format(path))
  end
  return path
end

describe("server_args.built_binary_name", function()
  it("carries .exe exactly on Windows", function()
    assert.are.equal(windows and "mdview-server.exe" or "mdview-server", server_args.built_binary_name())
  end)
end)

describe("server_args.spawnable", function()
  it("returns nil for a path that does not exist", function()
    with_tempdir(function(dir)
      assert.is_nil(server_args.spawnable(dir .. "/mdview-server"))
    end)
  end)

  it("finds the binary build:go writes on this platform", function()
    with_tempdir(function(dir)
      local base = dir .. "/mdview-server"
      local built = touch_executable(base .. (windows and ".exe" or ""))
      assert.are.equal(built, server_args.spawnable(base))
    end)
  end)

  it("on Windows, refuses an extension-less file and takes the .exe beside it", function()
    if not windows then
      -- Elsewhere the extension-less file *is* the binary — covered above.
      return
    end
    with_tempdir(function(dir)
      local base = touch_executable(dir .. "/mdview-server")
      assert.is_nil(server_args.spawnable(base))

      local exe = touch_executable(base .. ".exe")
      assert.are.equal(exe, server_args.spawnable(base))
    end)
  end)

  it("leaves a path that already carries an extension alone", function()
    with_tempdir(function(dir)
      local named = touch_executable(dir .. "/relay.bin")
      assert.are.equal(named, server_args.spawnable(named))
    end)
  end)

  it("gives the same answer whatever 'shell' is set to", function()
    if not windows then
      -- 'shell' never enters the question elsewhere.
      return
    end
    -- The case above hid for as long as it did because executable() on Windows
    -- only applies its $PATHEXT test when 'shell' does *not* look Unix-like.
    -- A developer running the suite from Git bash inherits shell=bash.exe and
    -- sees green; CI's nvim falls back to the cmd.exe default and sees red.
    -- uv.spawn() calls CreateProcessW directly and never consults a shell, so
    -- the two must agree — whichever way, this is a setting that cannot change
    -- whether a file starts.
    with_tempdir(function(dir)
      local named = touch_executable(dir .. "/relay.bin")
      local saved = vim.o.shell
      local seen = {}
      local ok, err = pcall(function()
        -- Indexed, not appended: a nil result must leave a hole for the
        -- assertion below to report, not silently shift the next answer down.
        for i, sh in ipairs({ "cmd.exe", "bash.exe" }) do
          vim.o.shell = sh
          seen[i] = server_args.spawnable(named)
        end
      end)
      vim.o.shell = saved
      assert(ok, err)
      assert.are.equal(named, seen[1])
      assert.are.equal(named, seen[2])
    end)
  end)
end)

describe("server_args.resolve: dev relay with the release client bundle", function()
  -- resolve_binary() and resolve_web_root() decide independently. A checkout
  -- with a built relay (native/server/mdview-server) but no dist/client — it is
  -- gitignored, so `git pull` never brings one — used to pair the dev relay
  -- with the client bundle of the pinned release without a word, and client
  -- features newer than that release (`:MDView edit`) silently did nothing.
  local install = require("mdview.adapter.install")
  local config = require("mdview.config")

  --- Run `fn(root, notes)` against a fake checkout at `root` whose release
  --- assets live under `root/release`; `notes` collects WARN notifications.
  ---@param fn fun(root: string, notes: string[])
  ---@return nil
  local function with_checkout(fn)
    with_tempdir(function(root)
      vim.fn.mkdir(root .. "/native/server", "p")
      vim.fn.mkdir(root .. "/release/client", "p")
      local notes = {}
      local saved = {
        root = server_args._root,
        dev = config.defaults.dev,
        env_bin = vim.env.MDVIEW_DEV_BINARY,
        env_web = vim.env.MDVIEW_DEV_WEB_ROOT,
        ensure_binary = install.ensure_binary,
        ensure_client_bundle = install.ensure_client_bundle,
        notify = vim.notify,
      }
      server_args._root = root
      server_args._reset_warned()
      config.defaults.dev = {}
      vim.env.MDVIEW_DEV_BINARY = nil
      vim.env.MDVIEW_DEV_WEB_ROOT = nil
      install.ensure_binary = function()
        return touch_executable(root .. "/release/mdview-server" .. (windows and ".exe" or "")), nil
      end
      install.ensure_client_bundle = function()
        return root .. "/release/client", nil
      end
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
          notes[#notes + 1] = msg
        end
      end
      local ok, err = pcall(fn, root, notes)
      vim.notify = saved.notify
      install.ensure_binary = saved.ensure_binary
      install.ensure_client_bundle = saved.ensure_client_bundle
      vim.env.MDVIEW_DEV_BINARY = saved.env_bin
      vim.env.MDVIEW_DEV_WEB_ROOT = saved.env_web
      config.defaults.dev = saved.dev
      server_args._root = saved.root
      server_args._reset_warned()
      if not ok then
        error(err, 0)
      end
    end)
  end

  ---@param root string
  ---@return string
  local function build_relay(root)
    return touch_executable(root .. "/native/server/mdview-server" .. (windows and ".exe" or ""))
  end

  ---@param root string
  ---@return string dir
  local function build_client(root)
    local dir = root .. "/dist/client"
    vim.fn.mkdir(dir, "p")
    touch_executable(dir .. "/index.html")
    return dir
  end

  ---@param args string[]
  ---@return string|nil
  local function web_root_arg(args)
    for i, a in ipairs(args) do
      if a == "--web-root" then
        return args[i + 1]
      end
    end
    return nil
  end

  it("warns once, naming npm run build:client, for a local relay without dist/client", function()
    with_checkout(function(root, notes)
      local relay = build_relay(root)
      local cmd, args = server_args.resolve()
      assert.are.equal(relay, cmd)
      assert.are.equal(root .. "/release/client", web_root_arg(args))
      assert.are.equal(1, #notes)
      assert.is_truthy(notes[1]:find("npm run build:client", 1, true))

      server_args.resolve()
      assert.are.equal(1, #notes)
    end)
  end)

  it("warns for dev.binary_path with the release bundle too", function()
    with_checkout(function(root, notes)
      local relay = touch_executable(root .. "/elsewhere" .. (windows and ".exe" or ""))
      config.defaults.dev = { binary_path = relay }
      local cmd = server_args.resolve()
      -- expand() turns the separators native; compare the paths, not spellings.
      assert.are.equal(vim.fs.normalize(relay), vim.fs.normalize(cmd))
      assert.are.equal(1, #notes)
      assert.is_truthy(notes[1]:find("npm run build:client", 1, true))
    end)
  end)

  -- `:MDView standalone` picks its bundle with the same two functions (resolve_web_root, warn_mismatch_once)
  it("standalone: the checkout's dist/client belongs to a local relay, a release bundle is warned about", function()
    with_checkout(function(root, notes)
      build_relay(root)
      local path, _, source = server_args.resolve_web_root()
      assert.are.equal(root .. "/release/client", path)
      assert.are.equal("release", source)
      server_args.warn_mismatch_once({ path = "relay", source = "local" }, { path = path, source = source })
      assert.are.equal(1, #notes)
      assert.is_truthy(notes[1]:find("npm run build:client", 1, true))

      local dir = build_client(root)
      local path2, _, source2 = server_args.resolve_web_root()
      assert.are.equal(dir, path2)
      assert.are.equal("local", source2)
      server_args._reset_warned()
      server_args.warn_mismatch_once({ path = "relay", source = "local" }, { path = path2, source = source2 })
      assert.are.equal(1, #notes, "a current local bundle with a local relay stays quiet")
    end)
  end)

  it("stays quiet when the checkout has its own dist/client", function()
    with_checkout(function(root, notes)
      build_relay(root)
      local dir = build_client(root)
      local _, args = server_args.resolve()
      assert.are.equal(dir, web_root_arg(args))
      assert.are.equal(0, #notes)
    end)
  end)

  it("stays quiet for release relay with release bundle", function()
    with_checkout(function(_, notes)
      server_args.resolve()
      assert.are.equal(0, #notes)
    end)
  end)

  ---@param path string
  ---@param age_s integer seconds before now
  ---@return nil
  local function age(path, age_s)
    local t = os.time() - age_s
    assert((vim.uv or vim.loop).fs_utime(path, t, t))
  end

  ---@param root string
  ---@param rel string path below the checkout
  ---@return string
  local function write_source(root, rel)
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "// source" }, path)
    return path
  end

  it("warns when a client source changed after dist/client was built", function()
    with_checkout(function(root, notes)
      build_relay(root)
      local dir = build_client(root)
      age(write_source(root, "src/client/main.ts"), 3 * 86400)
      age(dir .. "/index.html", 2 * 86400)
      -- What a pull that touches the client does: the file is written now.
      write_source(root, "src/client/transport/ws.ts")
      server_args.resolve()
      assert.are.equal(1, #notes)
      assert.is_truthy(notes[1]:find("older than its source", 1, true))
      assert.is_truthy(notes[1]:find("ws.ts", 1, true))
      assert.is_truthy(notes[1]:find("npm run build:client", 1, true))
    end)
  end)

  it("warns when only the wasm renderer sources are newer", function()
    with_checkout(function(root, notes)
      build_relay(root)
      local dir = build_client(root)
      age(dir .. "/index.html", 86400)
      write_source(root, "native/wasm-render/src/lib.rs")
      server_args.resolve()
      assert.are.equal(1, #notes)
      assert.is_truthy(notes[1]:find("lib.rs", 1, true))
    end)
  end)

  it("stays quiet when only the relay was rebuilt after dist/client", function()
    -- `npm run build:go` / the post-commit hook after a Go-only change: the
    -- relay is days newer than dist/client, yet the bundle is current.
    with_checkout(function(root, notes)
      local relay = build_relay(root)
      local dir = build_client(root)
      age(write_source(root, "src/client/main.ts"), 4 * 86400)
      age(dir .. "/index.html", 3 * 86400)
      age(relay, 0)
      server_args.resolve()
      assert.are.equal(0, #notes)
    end)
  end)

  it("sources() reports the mix without downloading, and health.check() survives it", function()
    with_checkout(function(root)
      build_relay(root)
      install.ensure_client_bundle = function()
        error("sources() must not download")
      end
      local src = server_args.sources()
      assert.are.equal("local", src.binary.source)
      assert.are.equal("release", src.web_root.source)
      assert.is_truthy(server_args.mismatch(src.binary, src.web_root))
      local ok, err = pcall(require("mdview.health").check)
      assert.is_true(ok, tostring(err))
    end)
  end)
end)
