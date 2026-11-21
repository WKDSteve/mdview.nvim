---@module 'mdview.init'
-- Module entrypoint for mdview.nvim.
-- Integrates browser autostart handle storage and stop-time cleanup.

-- lib.nvim is a HARD dependency (cross-platform helpers, usercmd registration,
-- structured logging). Several requires below pull it in transitively, so
-- probe it first and fail with one actionable line instead of a deep stack
-- trace from some inner module. :checkhealth mdview reports the same.
if not pcall(require, "lib.nvim.cross.platform.is_windows") then
  error(
    'mdview.nvim requires lib.nvim — add "WKDSteve/lib.nvim" to your plugin '
      .. "manager's dependencies (see README). Run :checkhealth mdview for details."
  )
end

local cfg = require("mdview.config")
local runner = require("mdview.adapter.runner")
local events = require("mdview.core.events")
local session = require("mdview.core.session")
local browser_adapter = require("mdview.adapter.browser")
local state = require("mdview.core.state")
local normalize = require("mdview.helper.normalize")

local notify = require("lib.nvim.notify").create("").notify

local M = {}

local ws_client = require("mdview.adapter.ws_client")
-- Defined below `M.open`, which hands over to them.
local open_tab, open_view

M.config = cfg.defaults

---@param opts table|nil supports nested overrides, e.g. { browser = { browser = "firefox" } }
---@return nil
function M.setup(opts)
  -- Warn about unknown/misplaced keys BEFORE merge (merge would fold them into
  -- defaults and hide them) — catches e.g. a top-level `click_navigate` that
  -- belongs under `experimental`.
  cfg.validate(opts)
  cfg.merge(opts)

  -- Resolve browser at setup time and notify user if resolution failed
  require("mdview.config.browser").resolve_with_notify()
  require("mdview.bindings.usrcmds").attach()
  -- Opt-in only: maps nothing unless setup() set a lhs under `keymaps`.
  require("mdview.bindings.keymaps").attach(cfg.defaults.keymaps)

  -- One-time (persisted across restarts) popup on the first setup() after
  -- installing this plugin: which CLI tools it needs and why
  -- (docs/install.json). `:Lib deps show mdview.nvim` thereafter.
  -- `cfg.defaults.deps_popup = false` (set right in the setup() spec,
  -- config/DEFAULTS.lua) disables it for this plugin specifically.
  -- pcall'd: an older lib.nvim without lib.nvim.deps mustn't break setup()
  -- over an informational popup.
  if cfg.defaults.deps_popup ~= false then
    local ok_deps, deps = pcall(require, "lib.nvim.deps")
    if ok_deps then
      deps.show_once("mdview.nvim")
    end
  end
end

---@class MDView.OpenOpts
---@field bufnr? integer # buffer to preview (default: the current one)
---@field render? fun(bufnr: integer): string[] # makes `bufnr` a generated view: the browser shows these Markdown lines, not the buffer text (see mdview.core.generated)
---@field name? string # generated view: its room, set as the buffer name (e.g. "caselog://case/app.log"); default: the buffer's own name
---@field on_click? fun(target: string, ctx: MDView.Generated.ClickContext) # generated view: a clicked relative link (`[x](entry/42)` -> "entry/42")
---@field browser_url? string
---@field browser_cmd? string
---@field browser_args? table

--- Open a browser tab for a buffer against the running mdview-server session.
--- Pushes the buffer's content first so the new tab has something to render
--- instead of waiting for the next edit.
---
--- Without `render` this needs a running session (`:MDView start`) and a buffer
--- with a file name. With `render` the buffer becomes a generated view first
--- (any buftype, `nofile` included; see `mdview.core.generated`): mdview asks
--- `render(bufnr)` for the Markdown, pushes again on `TextChanged` and on
--- `mdview.refresh(bufnr)`, hands clicked relative links to `on_click`, and ends
--- the view when the buffer is deleted. If no session runs yet and the view is
--- the current buffer, the session is started for it (`:MDView start`).
---@param opts MDView.OpenOpts|nil
---@return boolean ok
function M.open(opts)
  opts = opts or {}

  local buf = opts.bufnr
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end

  if opts.render ~= nil then
    local ok_reg, reg_err = require("mdview.core.generated").register(buf, {
      name = opts.name,
      render = opts.render,
      on_click = opts.on_click,
    })
    if not ok_reg then
      notify("[mdview] open: " .. tostring(reg_err), vim.log.levels.ERROR)
      return false
    end
  elseif opts.name ~= nil or opts.on_click ~= nil then
    notify("[mdview] open: `name` and `on_click` need `render` (a generated view)", vim.log.levels.ERROR)
    return false
  end

  if not state.is_attached() or not state.get_server() then
    if opts.render ~= nil and buf == vim.api.nvim_get_current_buf() then
      -- The start path previews the current buffer, which is this view.
      require("mdview.bindings.usrcmds.start").run({})
      return state.is_attached()
    end
    notify("[mdview] no mdview session running — start one first with :MDView start", vim.log.levels.WARN)
    return false
  end

  local key = normalize.path(vim.api.nvim_buf_get_name(buf))
  if not key or key == "" then
    notify("[mdview] current buffer has no file path to preview", vim.log.levels.WARN)
    return false
  end

  if opts.render ~= nil or require("mdview.core.generated").is(buf) then
    -- A generated view is opened idempotently: an open tab that already shows it
    -- (or, under "reuse", the one tab) is used instead of a further one. Which
    -- tabs are open is the relay's to say, so the rest happens in its answer.
    ws_client.tab_rooms(function(tabs)
      open_view(buf, key, opts, tabs)
    end)
    return true
  end

  return open_tab(buf, key, opts)
end

--- Opens a browser tab for `buf`'s room `key` and seeds it (the tail of `M.open`).
---@param buf integer
---@param key string
---@param opts MDView.OpenOpts
---@return boolean ok
function open_tab(buf, key, opts)
  -- This tab will watch `key`'s room; record it before seeding so the seed
  -- (and, in "reuse" behavior, later live pushes) route to this room.
  state.set_preview_key(key)

  -- An explicit :MDView open IS a request to preview this buffer, so a live
  -- pin comes along instead of blocking the document it was just asked for.
  require("mdview.core.pin").follow(buf)

  -- best-effort: seed the relay with current content so the new tab isn't
  -- empty. Force a full snapshot so the new tab's LastPayload is whole text
  -- (not a diff) when experimental.line_diff is on.
  pcall(require("mdview.bindings.autocmds.live_push").push_buffer_changes, buf, { full = true })

  local launcher = require("mdview.bindings.usrcmds.start.server.launcher")
  local browser_url = launcher.resolve_browser_url({ browser_url = opts.browser_url, key = key })

  local browser_defaults = require("mdview.config.browser").defaults
  local browser_opts = {
    open_mode = browser_defaults.open_mode,
    focus = browser_defaults.focus,
    browser_cmd = opts.browser_cmd or browser_defaults.resolved_browser_cmd,
    browser_args = opts.browser_args or browser_defaults.browser_args,
    on_exit = function(_, code)
      require("mdview.helper.log").debug(("browser exited with code %s"):format(tostring(code)), nil, "open", true)
      if browser_defaults.open_mode == "isolated" and browser_defaults.stop_on_browser_exit then
        vim.schedule(function()
          require("mdview.bindings.usrcmds.stop").stop()
        end)
      end
    end,
  }

  local ok, handle_or_err = pcall(browser_adapter.open, browser_url, browser_opts)
  if ok and handle_or_err then
    state.set_browser(handle_or_err)
    notify("[mdview] opened preview: " .. browser_url, vim.log.levels.INFO)
    return true
  end

  notify(("[mdview] failed to open browser: %s"):format(tostring(handle_or_err)), vim.log.levels.ERROR)
  return false
end

--- Decides, once the relay told which rooms have a tab (`tabs`, nil when it did
--- not say), whether `open` of a generated view needs a tab of its own.
---
---   * a tab already watches the view's room (`browser.behavior` other than
---     "reuse"): the view is only pushed again;
---   * "reuse" and the one tab is open: the view is brought into that tab, even
---     when it shows another document right now (the room stays the tab's own);
---   * otherwise (no tab, or the relay did not answer): a tab is opened.
---@param buf integer
---@param key string
---@param opts MDView.OpenOpts
---@param tabs string[]|nil
---@return nil
function open_view(buf, key, opts, tabs)
  if not vim.api.nvim_buf_is_valid(buf) or not state.is_attached() or not state.get_server() then
    return
  end
  local room
  if tabs then
    local reuse = (require("mdview.config.browser").defaults.behavior or "reuse") == "reuse"
    local current = state.get_preview_key()
    if reuse then
      if current and vim.tbl_contains(tabs, current) then
        room = current
      end
    elseif vim.tbl_contains(tabs, key) then
      room = key
    end
  end
  if not room then
    open_tab(buf, key, opts)
    return
  end
  state.set_preview_key(room)
  require("mdview.core.pin").follow(buf)
  pcall(require("mdview.bindings.autocmds.live_push").push_buffer_changes, buf, { full = true, explicit = true })
  notify("[mdview] the view is already open in a tab: " .. key, vim.log.levels.INFO)
end

--- Push a generated view again (see `M.open` with `render`): for changes its
--- buffer text does not show, such as a filter or folds. Throttled like a text
--- change; a no-op without a running session.
---@param bufnr integer|nil # default: the current buffer
---@return boolean pushed # false: not a generated view, or no session running
function M.refresh(bufnr)
  return require("mdview.core.generated").refresh(bufnr or 0)
end

-- ADD: testfunctions
-- Expose internals for REPL/testing
M._session = session
M._runner = runner
M._events = events
M._browser_adapter = browser_adapter

return M
