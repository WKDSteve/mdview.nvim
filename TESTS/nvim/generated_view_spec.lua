---@module 'tests.nvim.generated_view_spec'
-- Generated views (mdview.core.generated, `require("mdview").open({ render = … })`):
-- a `nofile` scratch buffer whose preview is the Markdown its owner renders. The
-- relay is faked (ws_client stubbed, every send recorded): nothing here touches
-- the network.

---@diagnostic disable: undefined-global, duplicate-set-field

local ws = require("mdview.adapter.ws_client")
local state = require("mdview.core.state")
local session = require("mdview.core.session")
local config = require("mdview.config")
local live = require("mdview.bindings.autocmds.live_push")
local generated = require("mdview.core.generated")
local previewable = require("mdview.helper.previewable")
local mirror = require("mdview.core.mirror")
local inbound = require("mdview.adapter.inbound_poll")
local mdview = require("mdview")

local NAME = "caselog://case-1/app.log.md"

local saved = {}
local sent, docs, scrolls, spans, controls, notes

--- Fake relay: record what would go out, never send.
local function install()
  saved = {
    send_content = ws.send_content,
    send_doc = ws.send_doc,
    send_scroll = ws.send_scroll,
    send_spans = ws.send_spans,
    send_control = ws.send_control,
    wait_ready = ws.wait_ready,
    notify = vim.notify,
    attached = state.is_attached(),
    get_server = state.get_server,
    preview_key = state.get_preview_key(),
    behavior = config.defaults.browser.behavior,
    highlighter = config.defaults.browser.highlighter,
    throttle = config.defaults.live_push_throttle_ms,
  }
  sent, docs, scrolls, spans, controls, notes = {}, {}, {}, {}, {}, {}
  ws.send_content = function(target, lines, opts)
    sent[#sent + 1] = { target = target, lines = vim.deepcopy(lines), full = opts and opts.full }
  end
  ws.send_doc = function(target, path)
    docs[#docs + 1] = { target = target, path = path }
  end
  ws.send_scroll = function(...)
    scrolls[#scrolls + 1] = { ... }
  end
  ws.send_spans = function(key, json)
    spans[#spans + 1] = { key = key, json = json }
  end
  ws.send_control = function(key, json)
    controls[#controls + 1] = { key = key, json = json }
  end
  ws.wait_ready = function(cb)
    cb(true)
  end
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  config.defaults.browser.behavior = "reuse"
  config.defaults.live_push_throttle_ms = 20
  state.set_preview_key(nil)
  session.init()
  live._last_doc = {}
end

local function restore()
  for bufnr in pairs(generated._views) do
    generated.unregister(bufnr)
  end
  ws.send_content, ws.send_doc, ws.send_scroll, ws.send_spans, ws.send_control, ws.wait_ready =
    saved.send_content, saved.send_doc, saved.send_scroll, saved.send_spans, saved.send_control, saved.wait_ready
  vim.notify = saved.notify
  state.set_attached(saved.attached)
  state.get_server = saved.get_server
  state.set_preview_key(saved.preview_key)
  config.defaults.browser.behavior = saved.behavior
  config.defaults.browser.highlighter = saved.highlighter
  config.defaults.live_push_throttle_ms = saved.throttle
  pcall(vim.api.nvim_del_augroup_by_name, "mdview_generated_spec")
end

--- A scratch buffer as an owner plugin makes it: `nofile`, not listed, its text
--- a log, not Markdown.
---@return integer
local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "caselog", { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "12:00:01 INFO start", "12:00:02 ERROR boom" })
  return buf
end

--- The owner's state: what the view shows depends on a filter the buffer text
--- does not carry.
local filter = "all"
local function render(bufnr)
  local out = { "# app.log", "" }
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if filter == "all" or line:find(filter, 1, true) then
      out[#out + 1] = ("- [%s](entry/%d)"):format(line, i)
    end
  end
  return out
end

local function settle(cond)
  return vim.wait(1000, cond, 5)
end

describe("generated view: registration", function()
  local buf
  before_each(function()
    install()
    filter = "all"
    buf = scratch()
  end)
  after_each(function()
    restore()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("makes a nofile buffer previewable under its name, but not a line-for-line source", function()
    assert.is_false(previewable.is(buf), "a plain nofile buffer is not previewed")
    assert.is_true(generated.register(buf, { name = NAME, render = render }))
    assert.are.equal("nofile", vim.bo[buf].buftype, "the buffer stays nofile")
    assert.are.equal(NAME, vim.api.nvim_buf_get_name(buf))
    assert.is_true(previewable.is(buf))
    assert.is_false(previewable.mirrors_source(buf))
    assert.are.equal(buf, generated.by_name(NAME))
  end)

  it("every preview route reads the rendering, never the buffer text", function()
    generated.register(buf, { name = NAME, render = render })
    local want = { "# app.log", "", "- [12:00:01 INFO start](entry/1)", "- [12:00:02 ERROR boom](entry/2)" }
    assert.are.same(want, mirror.lines(buf))
    assert.are.same(want, mirror.lines_for_path(NAME))
  end)

  it("refuses a bad contract with a reason", function()
    local ok, err = generated.register(buf, { name = NAME })
    assert.is_false(ok)
    assert.matches("render", err)
    ok, err = generated.register(buf, { render = render })
    assert.is_false(ok, "an unnamed scratch buffer needs a name")
    assert.matches("name", err)
    ok, err = generated.register(buf, { name = NAME, render = render, on_click = "nope" })
    assert.is_false(ok)
    assert.matches("on_click", err)
    assert.is_false(generated.is(buf))
  end)

  it("refuses a name the browser would not render as Markdown", function()
    local ok, err = generated.register(buf, { name = "caselog://case-1/app.log", render = render })
    assert.is_false(ok)
    assert.matches("must end in .md", err)
    assert.are.equal("", vim.api.nvim_buf_get_name(buf), "the buffer was not renamed")
    assert.is_true(generated.register(buf, { name = "x://a/b.MarkDown", render = render }))
  end)

  it("refuses a name another view already has", function()
    local other = scratch()
    assert.is_true(generated.register(other, { name = NAME, render = render }))
    local ok, err = generated.register(buf, { name = NAME, render = render })
    assert.is_false(ok)
    assert.matches("already", err)
    pcall(vim.api.nvim_buf_delete, other, { force = true })
  end)

  it("shows a failing render as an error page and reports it once", function()
    generated.register(buf, {
      name = NAME,
      render = function()
        error("parser exploded")
      end,
    })
    local a = mirror.lines(buf)
    local b = mirror.lines(buf)
    assert.matches("could not be rendered", a[1])
    assert.are.same(a, b)
    local errors = vim.tbl_filter(function(n)
      return n.level == vim.log.levels.ERROR
    end, notes)
    assert.are.equal(1, #errors, "one report per failure, not one per push")
    assert.matches("parser exploded", errors[1].msg)
  end)

  it("rejects a rendering that is not a list of strings", function()
    generated.register(buf, {
      name = NAME,
      render = function()
        return { "ok", 42 }
      end,
    })
    assert.matches("could not be rendered", mirror.lines(buf)[1])
  end)
end)

describe("generated view: pushes", function()
  local buf
  before_each(function()
    install()
    filter = "all"
    buf = scratch()
    vim.api.nvim_set_current_buf(buf)
    generated.register(buf, { name = NAME, render = render })
    state.set_attached(true)
    state.get_server = function()
      return {}
    end
    live.attach(vim.api.nvim_create_augroup("mdview_generated_spec", { clear = true }))
  end)
  after_each(function()
    live._cancel_pending()
    restore()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("pushes the rendering into the view's own room and announces the view", function()
    live.push_buffer_changes(buf, { full = true })
    assert.are.equal(1, #sent)
    assert.are.equal(NAME, sent[1].target)
    assert.are.same(render(buf), sent[1].lines)
    assert.are.same({ target = NAME, path = NAME }, docs[1])
  end)

  it("refresh pushes a new rendering without a text change (filter, folds)", function()
    live.push_buffer_changes(buf, { full = true })
    filter = "ERROR"
    assert.is_true(mdview.refresh(buf))
    assert.is_true(settle(function()
      return #sent >= 2
    end))
    assert.are.same({ "# app.log", "", "- [12:00:02 ERROR boom](entry/2)" }, sent[#sent].lines)
  end)

  it("a text change of the buffer pushes by itself (TextChanged)", function()
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "12:00:03 WARN slow" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    assert.is_true(settle(function()
      return #sent >= 1
    end))
    assert.are.equal("- [12:00:03 WARN slow](entry/3)", sent[#sent].lines[5])
  end)

  it("refresh is a no-op without a session or for a buffer that is no view", function()
    local plain = scratch()
    assert.is_false(mdview.refresh(plain))
    state.set_attached(false)
    assert.is_false(mdview.refresh(buf))
    vim.wait(60, function()
      return false
    end, 10)
    assert.are.equal(0, #sent)
    pcall(vim.api.nvim_buf_delete, plain, { force = true })
  end)

  it("a view in the background does not take the reuse tab from another document", function()
    local doc = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(doc, "mdview_generated_spec_other.md")
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = doc })
    state.set_preview_key("the/tab")
    live.announce_document("the/tab", "mdview_generated_spec_other.md")
    vim.api.nvim_set_current_buf(doc)
    local before = #sent
    live.push_buffer_changes(buf, { full = true, reason = "refresh" })
    assert.are.equal(before, #sent, "the tab shows another document: no push")

    -- The tab still shows the view: a background refresh updates it.
    live.announce_document("the/tab", NAME)
    live.push_buffer_changes(buf, { full = true, reason = "refresh" })
    assert.are.equal(before + 1, #sent)
    assert.are.equal("the/tab", sent[#sent].target)
    pcall(vim.api.nvim_buf_delete, doc, { force = true })
  end)

  it("line-for-line features leave the view alone", function()
    live.push_buffer_changes(buf, { full = true })
    require("mdview.bindings.autocmds.scroll_sync").send_current_position(buf)
    assert.are.equal(0, #scrolls, "no cursor line: the log line is not a line on screen")

    config.defaults.browser.highlighter = "nvim"
    require("mdview.core.fence_spans").push(buf, NAME)
    assert.are.equal(1, #spans)
    assert.is_nil(spans[1].json, "no spans from the buffer, the tab highlights itself")
  end)

  it("a write-back from the browser is refused and the buffer stays as it is", function()
    live.push_buffer_changes(buf, { full = true })
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    inbound._handle_toggle(NAME, 3, true, NAME, "- [ ] x")
    assert.are.same(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("deleting the buffer ends the view and clears its room", function()
    live.push_buffer_changes(buf, { full = true })
    assert.are.equal(NAME, live.shown_document(NAME))
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.is_false(generated.is(buf))
    assert.is_nil(live.shown_document(NAME), "the room shows no document of this session any more")
    assert.matches("was closed", sent[#sent].lines[1], "the tab learns the view is gone")
    assert.are.equal(NAME, sent[#sent].target)
  end)
end)

describe("generated view: clicks (/nav bridge)", function()
  local buf, clicks
  before_each(function()
    install()
    filter = "all"
    clicks = {}
    buf = scratch()
    generated.register(buf, {
      name = NAME,
      render = render,
      on_click = function(target, ctx)
        clicks[#clicks + 1] = { target = target, ctx = ctx }
      end,
    })
    live.announce_document(NAME, NAME)
  end)
  after_each(function()
    restore()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("a relative link of the view goes to on_click, not to a file", function()
    local cur = vim.api.nvim_get_current_buf()
    inbound._handle_nav(NAME, "entry/2")
    assert.are.equal(1, #clicks)
    assert.are.equal("entry/2", clicks[1].target)
    assert.are.same({ bufnr = buf, name = NAME }, clicks[1].ctx)
    assert.are.equal(cur, vim.api.nvim_get_current_buf(), "no file was opened")
  end)

  it("an on_click that raises is reported, not thrown into the poll loop", function()
    generated._views[buf].on_click = function()
      error("owner bug")
    end
    inbound._handle_nav(NAME, "entry/1")
    assert.matches("owner bug", notes[#notes].msg)
  end)

  it("Back/Forward to the view shows its buffer again", function()
    inbound._handle_nav("some/room", NAME)
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.equal(0, #clicks)
  end)
end)

describe("mdview.open with render", function()
  local buf
  before_each(function()
    install()
    buf = scratch()
  end)
  after_each(function()
    restore()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("registers the view, and without a session for a background buffer says so", function()
    state.set_attached(false)
    assert.is_false(mdview.open({ bufnr = buf, name = NAME, render = render }))
    assert.is_true(generated.is(buf), "the view stays registered for a later :MDView start")
    assert.matches("no mdview session", notes[#notes].msg)
  end)

  it("refuses name/on_click without render", function()
    assert.is_false(mdview.open({ bufnr = buf, name = NAME }))
    assert.matches("need `render`", notes[#notes].msg)
    assert.is_false(generated.is(buf))
  end)
end)
