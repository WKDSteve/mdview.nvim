---@module 'tests.nvim.selection_sync_spec'
-- Covers the Neovim half of the visual-selection mirror: turning whatever
-- v / V / CTRL-V currently has selected into the (mode, line, byte column)
-- payload the browser client draws, and routing that payload to the room the
-- open tab actually watches.
--
-- The client half — mapping those coordinates onto DOM positions — is covered
-- in TESTS/client/selectionMarker.test.ts.

---@diagnostic disable: undefined-global, need-check-nil, duplicate-set-field

local ws = require("mdview.adapter.ws_client")
local state = require("mdview.core.state")
local selection_sync = require("mdview.bindings.autocmds.selection_sync")
local bcfg = require("mdview.config.browser")
local normalize = require("mdview.helper.normalize")

-- Capture what control.send hands the transport, and where it routes it.
local last_key, last_json
local orig_send_control = ws.send_control
ws.send_control = function(key, json)
  last_key, last_json = key, json
end

local function make_md_buffer(name, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function leave_visual()
  vim.cmd("normal! \27") -- <Esc>
end

describe("selection_sync.current", function()
  local buf = make_md_buffer("mdview_spec_selection.md", { "hello world", "second line", "third" })
  vim.api.nvim_set_current_buf(buf)
  vim.o.selection = "inclusive"

  it("is nil outside a visual mode", function()
    leave_visual()
    assert.is_nil(selection_sync.current())
  end)

  it("reports a charwise selection with 1-based byte columns", function()
    leave_visual()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v4l") -- "hello" -> columns 1..5 on line 1
    local sel = selection_sync.current()
    leave_visual()
    assert.are.same({ mode = "char", sl = 1, sc = 1, el = 1, ec = 5 }, sel)
  end)

  it("orders the ends even when the cursor sits above the anchor", function()
    leave_visual()
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    vim.cmd("normal! vk") -- anchor on line 2, cursor moves up to line 1
    local sel = selection_sync.current()
    leave_visual()
    assert.are.equal("char", sel.mode)
    assert.are.equal(1, sel.sl)
    assert.are.equal(2, sel.el)
  end)

  it("reports a linewise selection", function()
    leave_visual()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! Vj")
    local sel = selection_sync.current()
    leave_visual()
    assert.are.equal("line", sel.mode)
    assert.are.equal(1, sel.sl)
    assert.are.equal(2, sel.el)
  end)

  it("reports a blockwise selection with its columns ordered left to right", function()
    leave_visual()
    vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- column 5
    vim.cmd("normal! \22j2h") -- CTRL-V down one line, then left: cursor ends left of the anchor
    local sel = selection_sync.current()
    leave_visual()
    assert.are.equal("block", sel.mode)
    assert.are.equal(3, sel.sc)
    assert.are.equal(5, sel.ec)
  end)

  it("drops the character under the cursor when 'selection' is exclusive", function()
    leave_visual()
    vim.o.selection = "exclusive"
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v4l")
    local sel = selection_sync.current()
    leave_visual()
    vim.o.selection = "inclusive"
    assert.are.equal(4, sel.ec)
  end)

  -- 'selection' = "exclusive" must select what Neovim itself selects (its own
  -- `y` is the reference). Dropping the last character unconditionally turned
  -- `V` and `v` without a cursor move into "no selection": the preview stayed
  -- empty until the cursor moved once.
  ---@param keys string
  ---@param pos? integer[] start cursor, default { 1, 2 } (the first "l" of "hello")
  ---@return table|nil
  local function exclusive(keys, pos)
    leave_visual()
    vim.o.selection = "exclusive"
    vim.api.nvim_win_set_cursor(0, pos or { 1, 2 })
    vim.cmd("normal! " .. keys)
    local sel = selection_sync.current()
    leave_visual()
    vim.o.selection = "inclusive"
    return sel
  end

  it("exclusive: V on one line still selects that line", function()
    local sel = exclusive("V")
    assert.is_not_nil(sel)
    assert.are.same({ "line", 1, 3, 1, 3 }, { sel.mode, sel.sl, sel.sc, sel.el, sel.ec })
  end)

  it("exclusive: V over two lines keeps both lines whole", function()
    local sel = exclusive("Vj")
    assert.are.same({ "line", 1, 2 }, { sel.mode, sel.sl, sel.el })
  end)

  it("exclusive: v without a move selects the character under the cursor", function()
    local sel = exclusive("v")
    assert.is_not_nil(sel)
    assert.are.same({ "char", 1, 3, 1, 3 }, { sel.mode, sel.sl, sel.sc, sel.el, sel.ec })
  end)

  it("exclusive: a backwards v drops the anchor, the later end", function()
    local sel = exclusive("vh") -- Neovim yanks "e" of "hello"
    assert.are.same({ 1, 2, 1, 2 }, { sel.sl, sel.sc, sel.el, sel.ec })
  end)

  it("exclusive: v ending on the first column of a later line stops at the line before", function()
    local sel = exclusive("vj0")
    assert.are.same({ 1, 3, 1, 11 }, { sel.sl, sel.sc, sel.el, sel.ec })
  end)

  it("exclusive: CTRL-V without a move selects one column", function()
    local sel = exclusive("\22j")
    assert.are.same({ "block", 3, 3 }, { sel.mode, sel.sc, sel.ec })
  end)

  it("exclusive: CTRL-V with the cursor left of the anchor keeps both columns", function()
    local sel = exclusive("\22jh") -- Neovim yanks "el" on both lines
    assert.are.same({ 2, 3 }, { sel.sc, sel.ec })
  end)

  it("exclusive: CTRL-V with the cursor right of the anchor drops the cursor column", function()
    local sel = exclusive("\22jl")
    assert.are.same({ 3, 3 }, { sel.sc, sel.ec })
  end)

  -- Blockwise, what decides is the LATER end in buffer order, not the cursor:
  -- when it sits right of the earlier end, the rightmost column goes.
  it("exclusive: CTRL-V moved left on the same line drops the anchor column", function()
    local sel = exclusive("\22h") -- Neovim yanks "e"
    assert.are.same({ 1, 2, 1, 2 }, { sel.sl, sel.sc, sel.el, sel.ec })
  end)

  it("exclusive: CTRL-V up and left drops the anchor column", function()
    local sel = exclusive("\22kh", { 2, 2 }) -- Neovim yanks "e" and "e"
    assert.are.same({ 1, 2, 2, 2 }, { sel.sl, sel.sc, sel.el, sel.ec })
  end)

  it("exclusive: CTRL-V up and right keeps both columns", function()
    local sel = exclusive("\22kl", { 2, 2 }) -- Neovim yanks "ll" and "co"
    assert.are.same({ 1, 3, 2, 4 }, { sel.sl, sel.sc, sel.el, sel.ec })
  end)
end)

describe("selection_sync.send_current_selection", function()
  local buf = make_md_buffer("mdview_spec_selection_send.md", { "hello world", "second line" })
  local buf_key = normalize.path(vim.api.nvim_buf_get_name(buf))
  vim.api.nvim_set_current_buf(buf)
  vim.o.selection = "inclusive"
  state.set_server({ stub = true }) -- control.send is a no-op without a session
  bcfg.defaults.behavior = "new_tab" -- route to the buffer's own path
  bcfg.defaults.selection_sync = true -- off by default; switched on for these

  it("routes the selection to the room the tab watches", function()
    leave_visual()
    selection_sync.reset()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v4l")
    last_key, last_json = nil, nil
    selection_sync.send_current_selection(buf)
    leave_visual()
    assert.are.equal(buf_key, last_key)
    local json = assert(last_json, "a selection payload was sent")
    local msg = vim.json.decode(json)
    assert.are.equal("char", msg.selection.mode)
    assert.are.equal(5, msg.selection.ec)
  end)

  it("sends `false` — not an absent key — when the selection is gone", function()
    leave_visual()
    selection_sync.reset()
    last_json = nil
    selection_sync.send_current_selection(buf)
    -- vim.json.encode drops nil-valued keys; the client has to be TOLD, or it
    -- keeps drawing the selection that is no longer there.
    local json = assert(last_json, "a payload was sent")
    assert.are.equal(false, vim.json.decode(json).selection)
  end)

  it("does not repeat an unchanged selection", function()
    leave_visual()
    selection_sync.reset()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v4l")
    selection_sync.send_current_selection(buf)
    last_json = nil
    selection_sync.send_current_selection(buf)
    leave_visual()
    assert.is_nil(last_json)
  end)

  it("clears the highlight when the feature is switched off", function()
    leave_visual()
    selection_sync.reset()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v4l")
    selection_sync.send_current_selection(buf)
    bcfg.defaults.selection_sync = false
    last_json = nil
    selection_sync.send_current_selection(buf)
    leave_visual()
    bcfg.defaults.selection_sync = true
    local json = assert(last_json, "a payload was sent")
    assert.are.equal(false, vim.json.decode(json).selection)
  end)

  ws.send_control = orig_send_control
end)
