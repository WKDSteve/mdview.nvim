---@module 'tests.nvim.live_push_throttle_spec'
-- TextChanged pushes go through lib.nvim.patterns.throttle: the first one runs
-- at once, a burst collapses into ONE trailing push with the latest buffer,
-- and teardown drops a pending trailing push.

---@diagnostic disable: undefined-global

local ws = require("mdview.adapter.ws_client")
local live = require("mdview.bindings.autocmds.live_push")
local autocmds = require("mdview.bindings.autocmds")
local defaults = require("mdview.config").defaults

local GROUP = "MdviewLivePushThrottleSpec"

describe("live_push TextChanged throttle", function()
  local orig_ready, orig_push, orig_ms
  local pushed
  local made = {}

  local function md_buffer(name)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, name)
    made[#made + 1] = buf
    return buf
  end

  -- Drive the registered TextChanged callback itself (one autocmd per ft_pattern entry,
  -- all sharing it), no matter which other autocmds the session keeps around.
  local function text_changed(buf)
    local found = vim.api.nvim_get_autocmds({ group = GROUP, event = "TextChanged" })
    assert.is_true(#found >= 1)
    found[1].callback({ buf = buf, event = "TextChanged" })
  end

  before_each(function()
    orig_ready, orig_push, orig_ms = ws.wait_ready, live.push_buffer_changes, defaults.live_push_throttle_ms
    ---@diagnostic disable-next-line: duplicate-set-field
    ws.wait_ready = function(cb)
      cb(true)
    end
    pushed = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    live.push_buffer_changes = function(bufnr)
      pushed[#pushed + 1] = bufnr
    end
    defaults.live_push_throttle_ms = 60
    -- The harness may already have attached the session's own autocmds; they would fire too.
    pcall(autocmds.teardown)
    live.attach(vim.api.nvim_create_augroup(GROUP, { clear = true }))
  end)

  after_each(function()
    live._cancel_pending()
    pcall(vim.api.nvim_del_augroup_by_name, GROUP)
    for _, buf in ipairs(made) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    made = {}
    ws.wait_ready, live.push_buffer_changes, defaults.live_push_throttle_ms = orig_ready, orig_push, orig_ms
  end)

  it("pushes the first change at once and collapses a burst into one trailing push", function()
    local a, b = md_buffer("throttle_a.md"), md_buffer("throttle_b.md")
    pushed = {} -- creating the buffers may push through other autocmds
    text_changed(a)
    assert.are.same({ a }, pushed)
    text_changed(a)
    text_changed(b)
    assert.are.same({ a }, pushed, "inside the window nothing more runs yet")
    vim.wait(1000, function()
      return #pushed >= 2
    end, 5)
    assert.are.same({ a, b }, pushed, "one trailing push carries the latest buffer")
    vim.wait(150, function()
      return false
    end, 10)
    assert.are.equal(2, #pushed, "no further push without further edits")
  end)

  it("follows a changed live_push_throttle_ms without a re-attach", function()
    local a = md_buffer("throttle_d.md")
    pushed = {}
    text_changed(a)
    assert.are.equal(1, #pushed)
    text_changed(a) -- pending in the 60ms window
    defaults.live_push_throttle_ms = 10
    vim.wait(100, function()
      return false
    end, 10)
    text_changed(a) -- window long over: leading push at once
    assert.is_true(#pushed >= 2)
    local before = #pushed
    defaults.live_push_throttle_ms = 5000
    text_changed(a) -- rebuilt with the long window: the first call is leading
    assert.are.equal(before + 1, #pushed)
    text_changed(a)
    assert.are.equal(before + 1, #pushed, "inside the new, long window")
  end)

  it("drops the pending trailing push on teardown", function()
    local a = md_buffer("throttle_c.md")
    pushed = {}
    text_changed(a)
    text_changed(a)
    live._cancel_pending()
    vim.wait(150, function()
      return false
    end, 10)
    assert.are.equal(1, #pushed)
  end)

  it("keeps no hand-rolled timer state in live_push", function()
    local path = vim.api.nvim_get_runtime_file("lua/mdview/bindings/autocmds/live_push.lua", false)[1]
    local src = table.concat(vim.fn.readfile(path), "\n")
    assert.is_truthy(src:find("lib.nvim.patterns.throttle", 1, true))
    assert.is_nil(src:find("pending_timer", 1, true))
    assert.is_nil(src:find("last_sent_at", 1, true))
  end)
end)
