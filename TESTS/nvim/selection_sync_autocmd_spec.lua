---@module 'tests.nvim.selection_sync_autocmd_spec'
-- The mirror only works if its autocommands actually fire, and both of its
-- triggers are easy to get subtly wrong:
--
--   * the `ModeChanged` patterns match against "old_mode:new_mode", and the
--     blockwise mode is a literal CTRL-V byte inside a character class
--     (`*:[vV<C-v>]*`) — a pattern that matches nothing is indistinguishable
--     from a feature that is simply off;
--   * `CursorMoved` fires in Visual mode in Neovim (unlike old Vim), which is
--     what makes a *growing* selection follow.
--
-- So this drives the real thing: attach the autocmds, press keys, and check
-- that a payload came out.

---@diagnostic disable: undefined-global, need-check-nil, duplicate-set-field

local ws = require("mdview.adapter.ws_client")
local state = require("mdview.core.state")
local selection_sync = require("mdview.bindings.autocmds.selection_sync")
local bcfg = require("mdview.config.browser")

local sent = {}
local orig_send_control = ws.send_control
ws.send_control = function(_, json)
  sent[#sent + 1] = vim.json.decode(json).selection
end

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, "mdview_spec_selection_autocmd.md")
vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha bravo", "charlie delta", "echo" })
vim.api.nvim_set_current_buf(buf)

local orig_server = state.set_server({ stub = true })
local orig_behavior, orig_selection_sync = bcfg.defaults.behavior, bcfg.defaults.selection_sync
local orig_selection = vim.o.selection
bcfg.defaults.behavior = "new_tab"
bcfg.defaults.selection_sync = true -- off by default; switched on for these
vim.o.selection = "inclusive"

local group = vim.api.nvim_create_augroup("MdviewSelectionSyncSpec", { clear = true })
selection_sync.attach(group)
-- teardown() at the top level runs once every block of this file is done (also when one
-- raises), so the stubs stay in place for every case below.
teardown(function()
  vim.api.nvim_del_augroup_by_id(group)
  ws.send_control = orig_send_control
  state.set_server(orig_server)
  bcfg.defaults.behavior, bcfg.defaults.selection_sync = orig_behavior, orig_selection_sync
  vim.o.selection = orig_selection
end)

--- Type `keys` as if pressed, then let the autocmds run.
---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("selection_sync autocmds", function()
  it("fires on entering charwise visual mode", function()
    feed("<Esc>")
    selection_sync.reset()
    sent = {}
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed("v4l")
    feed("<Esc>")
    assert.is_true(#sent >= 1)
    assert.are.equal("char", sent[1].mode)
    assert.are.equal(1, sent[1].sl)
  end)

  it("fires on entering blockwise visual mode (the CTRL-V pattern really matches)", function()
    feed("<Esc>")
    selection_sync.reset()
    sent = {}
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed("<C-v>j2l")
    feed("<Esc>")
    local shapes = vim.tbl_map(function(s)
      return s and s.mode or "none"
    end, sent)
    assert.is_true(vim.tbl_contains(shapes, "block"))
  end)

  it("clears the highlight on leaving visual mode", function()
    feed("<Esc>")
    selection_sync.reset()
    sent = {}
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed("v4l")
    feed("<Esc>")
    assert.are.equal(false, sent[#sent])
  end)

  -- Entering a visual mode without moving: the ModeChanged push alone must
  -- describe the one-line selection, or the tab shows nothing until the
  -- cursor moves (reported for `V`).
  for _, case in ipairs({ { "V", "line" }, { "v", "char" }, { "<C-v>", "block" } }) do
    it("sends the selection on entering " .. case[2] .. "wise visual mode without moving", function()
      feed("<Esc>")
      selection_sync.reset()
      selection_sync.send_current_selection(buf) -- the tab knows: no selection
      sent = {}
      vim.api.nvim_win_set_cursor(0, { 2, 3 })
      feed(case[1])
      local last = sent[#sent]
      feed("<Esc>")
      assert.is_true(type(last) == "table", "no selection pushed on entering " .. case[2])
      assert.are.equal(case[2], last.mode)
      assert.are.same({ 2, 4, 2, 4 }, { last.sl, last.sc, last.el, last.ec })
    end)

    it("sends the selection again on re-entering " .. case[2] .. "wise mode on the same spot", function()
      feed("<Esc>")
      selection_sync.reset()
      vim.api.nvim_win_set_cursor(0, { 3, 1 })
      feed(case[1])
      feed("<Esc>")
      sent = {}
      feed(case[1])
      local last = sent[#sent]
      feed("<Esc>")
      assert.is_true(type(last) == "table", "no selection pushed on re-entering " .. case[2])
      assert.are.same({ 3, 2, 3, 2 }, { last.sl, last.sc, last.el, last.ec })
    end)
  end

  it("sends nothing at all in normal mode", function()
    feed("<Esc>")
    selection_sync.reset()
    selection_sync.send_current_selection(buf) -- primes the cache with "none"
    sent = {}
    feed("j")
    feed("k")
    assert.are.equal(0, #sent)
  end)
end)
