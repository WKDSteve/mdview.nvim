---@module 'mdview.adapter.server_args'
-- Resolves the (cmd, args, cwd) triple used to spawn the native
-- mdview-server process: ensures the platform binary and client bundle are
-- installed, generates a fresh per-session token, and stores it in state so
-- ws_client can attach it to /update and the browser tab can attach it to /ws.

local install = require("mdview.adapter.install")
local gen_token = require("mdview.helper.gen_token")
local notify = require("lib.nvim.notify").create("").notify

-- This repo's stated floor is Neovim 0.9, where vim.uv does not exist yet.
local uv = vim.uv or vim.loop

local M = {}

-- Test seam: when set, stands in for this checkout's root, so a spec can model
-- a checkout with a built relay but no `dist/client`.
---@type string|nil
M._root = nil

--- Absolute path to this mdview.nvim checkout, derived from this file's own
--- location (<root>/lua/mdview/adapter/server_args.lua). Lets the plugin find a
--- build sitting inside its own checkout without the user hardcoding a path.
---@return string
local function plugin_root()
  if M._root then
    return M._root
  end
  local this = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fn.fnamemodify(this, ":p:h:h:h:h"))
end

--- File name `npm run build:go` gives the relay on this platform.
---@return string
local function built_binary_name()
  return vim.fn.has("win32") == 1 and "mdview-server.exe" or "mdview-server"
end
-- Exposed so callers can name the expected file in their own diagnostics.
M.built_binary_name = built_binary_name

--- The path `uv.spawn()` can actually start for `path`, or nil.
---
--- Not the same question as `executable()`, and on Windows wrong in both
--- directions:
---
--- * A name with no extension libuv resolves by appending .com/.exe/.bat/.cmd,
---   never trying the bare name — so an extension-less file spawns as ENOENT
---   however readable it is. `.exe` next to it is the real target, and pointing
---   an override at the extension-less name is easy to do, because that is what
---   `build:go` wrote until 2026-08-30.
--- * A name that already carries an extension libuv tries verbatim, whatever
---   that extension is. `executable()` asks something else entirely: whether
---   the name ends in a $PATHEXT entry — and it skips that test when 'shell'
---   looks Unix-like. So its answer moved with a setting `uv.spawn()` cannot
---   see (libuv calls CreateProcessW directly, never through a shell): a real
---   relay at `…/mdview-server.bin` was "spawnable" under a Git-bash 'shell'
---   and refused under the Windows default cmd.exe.
---
--- Windows has no exec bit, so existence is the whole question there — the
--- same thing libuv checks before handing the path to CreateProcessW. On Unix
--- the bit is real and `uv.spawn()` fails EACCES without it, so keep asking.
---@param path string
---@return string|nil
local function spawnable(path)
  if vim.fn.has("win32") ~= 1 then
    return vim.fn.executable(path) == 1 and path or nil
  end
  local candidate = path:match("%.[%a%d]+$") and path or (path .. ".exe")
  local stat = uv.fs_stat(candidate)
  return (stat and stat.type == "file") and candidate or nil
end
M.spawnable = spawnable

--- A relay binary built inside this checkout, if one exists. This is the
--- zero-config dev path: `npm run build:go` writes it next to the Go sources,
--- and a checkout that has one is by definition a dev checkout — a normal
--- lazy/packer install never ships one (it's gitignored). So auto-using it is
--- safe: it only ever triggers when a build is actually present.
---@return string|nil
local function local_built_binary()
  local base = plugin_root() .. "/native/server/mdview-server"
  local found = spawnable(base)
  if found then
    return found
  end

  -- A Windows checkout built before 2026-08-30 still holds the extension-less
  -- file this function used to hand to uv.spawn. Say so: the failure it caused
  -- was only ever visible as ":MDView start -> failed to start server process".
  if vim.fn.has("win32") == 1 and vim.fn.filereadable(base) == 1 then
    notify(
      ("[mdview] ignoring %q: Windows cannot spawn a binary without an extension. Run `npm run build:go` to rebuild it as %s."):format(
        base,
        built_binary_name()
      ),
      vim.log.levels.WARN
    )
  end
  return nil
end
-- Exposed so :MDView standalone can reuse the same zero-config dev build (it
-- also needs a --watch-capable relay, which the local build is and the pinned
-- release may not be).
M.local_built_binary = local_built_binary

--- The client bundle built inside this checkout, if present (`npm run
--- build:client` writes `dist/client`). Same self-gating logic as the binary.
---@return string|nil
local function local_built_web_root()
  local dir = plugin_root() .. "/dist/client"
  if vim.fn.filereadable(dir .. "/index.html") == 1 then
    return dir
  end
  return nil
end

---@alias mdview.AssetSource "dev"|"local"|"release"
--- "dev" = an explicit override (`dev.*` option or `$MDVIEW_DEV_*`), "local" =
--- a build inside this checkout, "release" = what `install` manages.

---@class mdview.AssetChoice
---@field path string|nil resolved path (for "release" possibly not downloaded yet)
---@field source mdview.AssetSource

--- The relay binary that wins over the release, if any: explicit
--- `dev.binary_path`, then `$MDVIEW_DEV_BINARY` (the only way a detached
--- instance — scripts/minimal_init.lua loads none of the user's Lua config —
--- can reach one), then a build inside this checkout (zero-config dev).
---@return string|nil path, mdview.AssetSource|nil source
local function dev_binary()
  local dev = require("mdview.config").defaults.dev or {}
  local override = dev.binary_path
  if not (type(override) == "string" and override ~= "") then
    override = vim.env.MDVIEW_DEV_BINARY
  end
  if type(override) == "string" and override ~= "" then
    local path = vim.fn.expand(override)
    local usable = spawnable(path)
    if usable then
      return usable, "dev"
    end
    -- A stale/typo'd override shouldn't brick start — warn and fall through
    -- to the auto-detected build / release, which usually works.
    notify(
      ("[mdview] dev.binary_path is not spawnable, ignoring it: %q (looked for %s)"):format(path, built_binary_name()),
      vim.log.levels.WARN
    )
  end
  local built = local_built_binary()
  if built then
    return built, "local"
  end
  return nil, nil
end

--- The client bundle that wins over the release, if any: `dev.web_root`,
--- `$MDVIEW_DEV_WEB_ROOT`, then a build inside this checkout.
---@return string|nil path, mdview.AssetSource|nil source
local function dev_web_root()
  local dev = require("mdview.config").defaults.dev or {}
  local override = dev.web_root
  if not (type(override) == "string" and override ~= "") then
    override = vim.env.MDVIEW_DEV_WEB_ROOT
  end
  if type(override) == "string" and override ~= "" then
    local path = vim.fn.expand(override)
    if vim.fn.isdirectory(path) == 1 then
      return path, "dev"
    end
    notify(("[mdview] dev.web_root is not a directory, ignoring it: %q"):format(path), vim.log.levels.WARN)
  end
  local built = local_built_web_root()
  if built then
    return built, "local"
  end
  return nil, nil
end

--- Relay binary the normal `:MDView start` path spawns: the dev one if there
--- is one, else whatever `install` manages (downloaded release).
---@internal
---@return string|nil path, string|nil err, mdview.AssetSource|nil source
local function resolve_binary()
  local path, source = dev_binary()
  if path then
    return path, nil, source
  end
  local installed, err = install.ensure_binary()
  return installed, err, "release"
end

--- Client bundle dir the normal `:MDView start` path passes as --web-root,
--- same precedence as resolve_binary.
---@internal
---@return string|nil path, string|nil err, mdview.AssetSource|nil source
local function resolve_web_root()
  local path, source = dev_web_root()
  if path then
    return path, nil, source
  end
  local installed, err = install.ensure_client_bundle()
  return installed, err, "release"
end

M.resolve_web_root = resolve_web_root

--- Which binary and bundle `:MDView start` would use, without downloading
--- anything (a release asset that is not installed yet still gets its path).
--- Read-only — for :checkhealth.
---@return { binary: mdview.AssetChoice, web_root: mdview.AssetChoice }
function M.sources()
  local status = install.status()
  local bin, bin_source = dev_binary()
  local web, web_source = dev_web_root()
  return {
    binary = { path = bin or status.binary_path, source = bin_source or "release" },
    web_root = { path = web or status.client_dir, source = web_source or "release" },
  }
end

---@param path string|nil
---@return integer|nil
local function mtime(path)
  local stat = path and uv.fs_stat(path)
  return stat and stat.mtime and stat.mtime.sec or nil
end

-- What `dist/client` is built from, relative to the checkout — the same set
-- scripts/rebuild-changed.sh rebuilds the client for. Directories are walked
-- (all small; `native/wasm-render/target` is deliberately not among them).
local CLIENT_SOURCE_DIRS = { "src/client", "native/wasm-render/src" }
local CLIENT_SOURCE_FILES = { "native/wasm-render/Cargo.toml", "package.json", "package-lock.json" }

--- The newest client source file in this checkout, or nil when there is none.
---
--- Dating `dist/client` against its own sources, not against the relay: the
--- relay is rebuilt on its own (`npm run build:go`, and the post-commit hook
--- rebuilds only the half whose sources changed), so a Go-only change leaves a
--- perfectly current bundle "older than the relay". A pull/checkout that changes
--- a client source writes that file now, which is what makes the bundle stale.
---@return string|nil path, integer|nil mtime
local function newest_client_source()
  local root = plugin_root()
  local best_path, best_time
  local function consider(path)
    local t = mtime(path)
    if t and (not best_time or t > best_time) then
      best_path, best_time = path, t
    end
  end
  local collect = require("lib.nvim.fs.collect_recursive")
  for _, dir in ipairs(CLIENT_SOURCE_DIRS) do
    local abs = root .. "/" .. dir
    if vim.fn.isdirectory(abs) == 1 then
      for _, path in ipairs((collect.files(abs))) do
        consider(path)
      end
    end
  end
  for _, file in ipairs(CLIENT_SOURCE_FILES) do
    consider(root .. "/" .. file)
  end
  return best_path, best_time
end

--- Why the chosen relay and client bundle do not belong together, or nil.
---
--- `resolve_binary` and `resolve_web_root` decide independently: a checkout
--- with `native/server/mdview-server(.exe)` but no (gitignored) `dist/client`
--- runs the dev relay against the client bundle of the pinned release. Client
--- features newer than that release (e.g. `:MDView edit`) then do nothing,
--- without any error anywhere — the browser simply ignores the message.
---@param binary mdview.AssetChoice
---@param web_root mdview.AssetChoice
---@return string|nil
function M.mismatch(binary, web_root)
  if binary.source == "release" then
    return nil
  end
  if web_root.source == "release" then
    local version = (require("mdview.config").defaults.install or {}).version
    return (
      "[mdview] a dev relay (%s) runs with the client bundle of release %s (%s); client features newer "
      .. "than that release will silently do nothing. Run `npm run build:client` in the mdview.nvim "
      .. "checkout, or set dev.web_root."
    ):format(tostring(binary.path), tostring(version), tostring(web_root.path))
  end
  if web_root.source == "local" then
    local web_time = mtime(web_root.path and (web_root.path .. "/index.html"))
    local src_path, src_time = newest_client_source()
    if web_time and src_time and src_time > web_time then
      return (
        "[mdview] the local client bundle %s (built %s) is older than its source %s (changed %s); "
        .. "run `npm run build:client` (`npm run build` after a native/wasm-render change) to bring it up to date."
      ):format(web_root.path, os.date("%Y-%m-%d %H:%M", web_time), src_path, os.date("%Y-%m-%d %H:%M", src_time))
    end
  end
  return nil
end

-- Messages already shown this session: `:MDView start` warns once, not on
-- every restart of the relay.
local warned = {}

---@param binary mdview.AssetChoice
---@param web_root mdview.AssetChoice
---@return nil
local function warn_mismatch_once(binary, web_root)
  local msg = M.mismatch(binary, web_root)
  if msg and not warned[msg] then
    warned[msg] = true
    notify(msg, vim.log.levels.WARN)
  end
end

M.warn_mismatch_once = warn_mismatch_once

--- Forget which mismatch warnings were shown (tests).
---@internal
---@return nil
function M._reset_warned()
  warned = {}
end

--- @param cwd_override string|nil # takes precedence over mdview.config.defaults.server_cwd, e.g. from `:MDView start cwd=...`
--- @return string|nil cmd
--- @return string[]|nil args
--- @return string|nil cwd
--- @return string|nil err
function M.resolve(cwd_override)
  local defaults = require("mdview.config").defaults
  local state = require("mdview.core.state")

  local bin_path, bin_err, bin_source = resolve_binary()
  if not bin_path then
    return nil, nil, nil, "failed to resolve mdview-server binary: " .. tostring(bin_err)
  end

  local web_root, web_err, web_source = resolve_web_root()
  if not web_root then
    return nil, nil, nil, "failed to resolve mdview client bundle: " .. tostring(web_err)
  end

  warn_mismatch_once(
    { path = bin_path, source = bin_source or "release" },
    { path = web_root, source = web_source or "release" }
  )

  local token = gen_token()
  state.set_token(token)

  local args = {
    "--port",
    tostring(defaults.server_port or 43219),
    "--token",
    token,
    "--web-root",
    web_root,
  }

  -- Opt-in WebTransport (HTTP/3): ask the relay to also serve /wt and print its
  -- cert hash (the runner parses it). Off by default → no UDP listener / no
  -- cert overhead.
  local experimental = defaults.experimental or {}
  if experimental.webtransport == true then
    args[#args + 1] = "--webtransport"
  end

  -- Opt-in shared relay: one relay for every Neovim instance, advertised in a
  -- discovery file (empty when shared_relay.enabled is off).
  vim.list_extend(args, require("mdview.adapter.shared_relay").spawn_args())

  local cwd = cwd_override
  if not cwd or cwd == "" then
    cwd = defaults.server_cwd
  end

  return bin_path, args, cwd, nil
end

return M
