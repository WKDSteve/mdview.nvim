---@module 'mdview.core.generated'
--- Generated views: a scratch buffer (usually `buftype=nofile`) whose preview is
--- not its own text but Markdown its owner produces on demand.
---
--- Another plugin registers the buffer through `require("mdview").open({ bufnr,
--- name, render, on_click })`. From then on:
---
---   * the buffer counts as previewable (helper/previewable), although it has no
---     file behind it;
---   * every route that reads the preview text (core/mirror) asks `render(bufnr)`
---     instead of reading the buffer: the browser shows the Markdown the owner
---     made, the buffer keeps whatever the owner wants it to hold;
---   * the room is the buffer's name (`name`, set on the buffer at registration):
---     one view, one room, as with a file;
---   * features that map buffer lines to document lines one to one (scroll and
---     selection sync, breadcrumbs, the browser write-back, fence spans) leave the
---     buffer alone: its lines are not the lines of what the browser shows;
---   * a clicked relative link in the view goes to `on_click(target, ctx)` instead
---     of being opened as a file (adapter/inbound_poll, the /nav bridge);
---   * deleting or wiping the buffer ends the view and clears its room.
---
--- The owner pushes a new rendering with `require("mdview").refresh(bufnr)` when
--- what the view shows changed without a text change (a filter, folds); a text
--- change of the buffer (`TextChanged`) pushes by itself.
---
--- The registry holds the callbacks only; the name is always read from the
--- buffer, so a later `:file` cannot leave a stale copy behind.

local api = vim.api

local M = {}

---@class MDView.Generated.ClickContext
---@field bufnr integer # the view's buffer
---@field name string # the view's room (normalized buffer name)

---@class MDView.Generated.Spec
---@field render fun(bufnr: integer): string[] # the Markdown lines the browser shows
---@field on_click? fun(target: string, ctx: MDView.Generated.ClickContext) # a clicked relative link of the view

---@class MDView.Generated.Options: MDView.Generated.Spec
---@field name? string # the view's room; becomes the buffer name (default: the buffer's own name)

---@class MDView.Generated.View
---@field render fun(bufnr: integer): string[]
---@field on_click? fun(target: string, ctx: MDView.Generated.ClickContext)
---@field group integer # augroup of the view's buffer-local autocmds
---@field failed string|nil # last render error that was reported (reported once until a render succeeds)

---@type table<integer, MDView.Generated.View>
M._views = {}

--- The view registered for `bufnr`, or nil.
---@param bufnr integer|nil
---@return MDView.Generated.View|nil
function M.get(bufnr)
  if type(bufnr) ~= "number" then
    return nil
  end
  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  return M._views[bufnr]
end

--- Whether `bufnr` is a registered generated view.
---@param bufnr integer|nil
---@return boolean
function M.is(bufnr)
  return M.get(bufnr) ~= nil
end

--- The view's room: its normalized buffer name.
---@param bufnr integer
---@return string|nil
function M.name(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return require("mdview.helper.normalize").path(name)
end

--- The buffer of the view whose room (normalized name) is `name`, or nil.
---@param name string|nil
---@return integer|nil bufnr
function M.by_name(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local norm = require("mdview.helper.normalize").path(name)
  for bufnr in pairs(M._views) do
    if M.name(bufnr) == norm then
      return bufnr
    end
  end
  return nil
end

--- What the browser shows for a render that failed: the error, visibly, instead
--- of an empty page or the previous text pretending to be current.
---@internal
---@param name string
---@param err string
---@return string[]
local function failure_lines(name, err)
  local lines = { "**mdview:** the view `" .. name .. "` could not be rendered.", "", "```text" }
  for line in (err .. "\n"):gmatch("(.-)\r?\n") do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = "```"
  return lines
end

--- Whether `name` ends in a Markdown extension. The browser decides by the
--- document's extension whether it renders Markdown or a code view, so the name
--- of a view (which is its document) has to carry one: `caselog://x/app.log.md`.
---@param name string
---@return boolean
function M.markdown_name(name)
  local ext = name:match("%.([%w]+)$")
  ext = ext and ext:lower()
  return ext == "md" or ext == "markdown" or ext == "mdx"
end

--- The Markdown lines of the view, from its `render` callback. Always a fresh
--- list of strings. A callback that raises or answers anything but a list of
--- strings is reported once (until it renders again) and shown as an error page.
---@param bufnr integer
---@return string[]
function M.lines(bufnr)
  local view = M.get(bufnr)
  if not view then
    return {}
  end
  local ok, res = pcall(view.render, bufnr)
  local err
  if not ok then
    err = tostring(res)
  elseif type(res) ~= "table" then
    err = "render returned " .. type(res) .. ", expected a list of strings"
  else
    local out = {}
    for i, line in ipairs(res) do
      if type(line) ~= "string" then
        err = ("render returned a %s at line %d, expected a string"):format(type(line), i)
        break
      end
      out[i] = line
    end
    if not err then
      view.failed = nil
      return out
    end
  end
  local name = M.name(bufnr) or ("buffer " .. bufnr)
  if view.failed ~= err then
    view.failed = err
    require("lib.nvim.notify").create("").notify(("[mdview] view %s: %s"):format(name, err), vim.log.levels.ERROR)
  end
  return failure_lines(name, err)
end

--- Whether a push of the view into `target` may go out now.
---
--- The current buffer always may: it is what the preview follows. A view in the
--- background (the owner refreshed it while the person works elsewhere) may only
--- update a room that is its own or that still shows it; under
--- `browser.behavior = "reuse"` the one tab's room may show another document by
--- now, which a background refresh must not take away.
---@param bufnr integer
---@param target string
---@return boolean
function M.may_push(bufnr, target)
  if bufnr == api.nvim_get_current_buf() then
    return true
  end
  local name = M.name(bufnr)
  if not name then
    return false
  end
  if target == name then
    return true
  end
  return require("mdview.bindings.autocmds.live_push").shown_document(target) == name
end

--- Hand a clicked link of the view to its `on_click`. Errors of the callback are
--- reported, never raised into the poll loop.
---@param bufnr integer
---@param target string
---@return boolean handled # false: the view has no `on_click`
function M.click(bufnr, target)
  local view = M.get(bufnr)
  if not view or not view.on_click then
    return false
  end
  local ctx = { bufnr = bufnr, name = M.name(bufnr) or "" }
  local ok, err = pcall(view.on_click, target, ctx)
  if not ok then
    require("lib.nvim.notify")
      .create("")
      .notify(("[mdview] on_click of %s failed: %s"):format(ctx.name, tostring(err)), vim.log.levels.ERROR)
  end
  return true
end

--- Push the view now, when a session runs (no-op otherwise).
---@internal
---@param bufnr integer
---@param opts table|nil # passed to live_push.push_buffer_changes
---@return nil
local function push_now(bufnr, opts)
  if not require("mdview.core.state").is_attached() then
    return
  end
  require("mdview.adapter.ws_client").wait_ready(function(ok)
    if ok and M.is(bufnr) and api.nvim_buf_is_valid(bufnr) then
      require("mdview.bindings.autocmds.live_push").push_buffer_changes(bufnr, opts)
    end
  end)
end

--- Clear what the session keeps for the view's room: the tab that still shows it
--- learns it is gone (a short notice instead of a stale page), and the room's
--- bookkeeping is dropped.
---@internal
---@param name string
---@return nil
local function clear_room(name)
  local live_push = require("mdview.bindings.autocmds.live_push")
  local rooms = {}
  for _, room in ipairs(live_push.rooms()) do
    if live_push.shown_document(room) == name then
      rooms[#rooms + 1] = room
    end
  end
  local attached = require("mdview.core.state").is_attached()
  local ws_client = require("mdview.adapter.ws_client")
  for _, room in ipairs(rooms) do
    if attached then
      pcall(ws_client.send_content, room, { "_The view `" .. name .. "` was closed in Neovim._" }, { full = true })
    end
    live_push.forget_room(room)
    pcall(require("mdview.core.display").forget_room, room)
  end
  require("mdview.core.session").buffers[name] = nil
  local pin = require("mdview.core.pin")
  if pin.get() == name then
    pin.clear()
  end
  -- A throttled push still pending for the buffer finds it no longer
  -- previewable (no view, and `nofile`) and does nothing.
end

--- End the view of `bufnr`: forget the callbacks, drop its autocmds and clear its
--- room. The buffer itself stays as it is. A no-op for a buffer without a view.
---@param bufnr integer
---@return boolean removed
function M.unregister(bufnr)
  local view = M._views[bufnr]
  if not view then
    return false
  end
  local name = M.name(bufnr)
  M._views[bufnr] = nil
  pcall(api.nvim_del_augroup_by_id, view.group)
  if name then
    clear_room(name)
  end
  return true
end

--- Register (or update) the view of `bufnr`.
---
--- `name` becomes the buffer's name when given and different (a `nofile` buffer
--- has no file behind its name, so nothing is written or read); without it the
--- buffer must already have a name. Either way it must end in `.md`, `.markdown`
--- or `.mdx` (`M.markdown_name`). A scheme such as `caselog://…` keeps the room
--- apart from every file path.
---@param bufnr integer
---@param spec MDView.Generated.Options
---@return boolean ok
---@return string|nil err
function M.register(bufnr, spec)
  if type(bufnr) ~= "number" or not api.nvim_buf_is_valid(bufnr) then
    return false, "bufnr is not a valid buffer"
  end
  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  if type(spec) ~= "table" or not vim.is_callable(spec.render) then
    return false, "render must be a function(bufnr) returning Markdown lines"
  end
  if spec.on_click ~= nil and not vim.is_callable(spec.on_click) then
    return false, "on_click must be a function(target, ctx)"
  end
  if spec.name ~= nil and (type(spec.name) ~= "string" or spec.name == "") then
    return false, "name must be a non-empty string"
  end

  local wanted = spec.name or api.nvim_buf_get_name(bufnr)
  if wanted ~= "" and not M.markdown_name(wanted) then
    return false,
      ("name %s must end in .md, .markdown or .mdx: the browser renders a document by its extension"):format(wanted)
  end

  if spec.name and spec.name ~= api.nvim_buf_get_name(bufnr) then
    local other = M.by_name(spec.name)
    if other and other ~= bufnr then
      return false, ("name %s is already the view of buffer %d"):format(spec.name, other)
    end
    local ok, err = pcall(api.nvim_buf_set_name, bufnr, spec.name)
    if not ok then
      return false, "cannot name the buffer " .. spec.name .. ": " .. tostring(err)
    end
  end
  if not M.name(bufnr) then
    return false, 'the buffer has no name; pass `name` (e.g. "myplugin://view.md")'
  end

  local old = M._views[bufnr]
  local group = old and old.group or api.nvim_create_augroup("mdview.generated." .. bufnr, { clear = true })
  M._views[bufnr] = { render = spec.render, on_click = spec.on_click, group = group, failed = nil }
  if old then
    return true
  end

  -- Buffer-local: the global live-push autocmds match `ft_pattern` against the
  -- buffer name, which a view (`caselog://…`) need not match. Not recorded: they
  -- live as long as one view, under a group named after its buffer.
  local autocmd = require("lib.nvim.bindings.autocmd")
  autocmd.create({ "TextChanged", "TextChangedI" }, function(args)
    require("mdview.bindings.autocmds.live_push").request_push(args.buf)
  end, {
    group = group,
    buffer = bufnr,
    record = false,
    desc = "[mdview] Push a generated view after its buffer changed",
  })
  autocmd.create("BufEnter", function(args)
    push_now(args.buf, { full = true, reason = "switch" })
  end, {
    group = group,
    buffer = bufnr,
    record = false,
    desc = "[mdview] Show a generated view again when its buffer is entered",
  })
  autocmd.create({ "BufDelete", "BufWipeout" }, function(args)
    M.unregister(args.buf)
  end, {
    group = group,
    buffer = bufnr,
    record = false,
    desc = "[mdview] End a generated view with its buffer",
  })
  return true
end

--- Push the current rendering of the view now (throttled like a text change).
--- For changes the buffer text does not show: a filter, folds.
---@param bufnr integer
---@return boolean pushed # false: no view, or no session running
function M.refresh(bufnr)
  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  if not M.is(bufnr) or not require("mdview.core.state").is_attached() then
    return false
  end
  require("mdview.bindings.autocmds.live_push").request_push(bufnr)
  return true
end

return M
