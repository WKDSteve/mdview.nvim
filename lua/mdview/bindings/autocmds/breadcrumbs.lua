---@module 'mdview.bindings.autocmds.breadcrumbs'
-- Records session breadcrumbs (mdview.core.breadcrumbs) as the cursor moves and
-- on buffer switches, so :MDView breadcrumbs can show/export a rough outline of
-- what was visited during the session. Gated behind config.breadcrumbs (default
-- true); throttled, and the recorder itself dedupes on (doc, heading), so this
-- stays off the hot path.

local api = vim.api
local defaults = require("mdview.config").defaults
local autocmd = require("lib.nvim.bindings.autocmd")
local hub = require("mdview.bindings.autocmds.enter_hub")

local M = {}

---@param group integer|nil
function M.attach(group)
  if defaults.breadcrumbs == false then
    return
  end

  local crumbs = require("mdview.core.breadcrumbs")
  crumbs.clear() -- fresh session

  -- Leading only: a crumb dropped inside the window is not worth a late write.
  local throttled = require("lib.nvim.patterns.throttle").new(function(buf)
    pcall(crumbs.record, buf)
  end, 300, { trailing = false })

  local function record(args)
    throttled.call(args.buf)
  end

  local opts = {
    desc = "[mdview] Record session breadcrumbs (document + heading over time)",
    pattern = defaults.ft_pattern,
  }
  if group then
    opts.group = group
  end
  autocmd.create({ "CursorMoved", "CursorMovedI" }, record, opts)
  -- Entering a buffer shares the session's BufEnter hub with the snapshot and
  -- buffer-switch handlers; the throttle above is shared by both routes.
  hub.register("mdview.breadcrumbs", {
    desc = "[mdview] Record a breadcrumb on entering a buffer",
    load = function(ctx)
      record(ctx.ev)
    end,
  })

  -- Seed the first breadcrumb for the current buffer (no BufEnter fires when a
  -- session starts on the already-current buffer).
  pcall(crumbs.record, api.nvim_get_current_buf())
end

return M
