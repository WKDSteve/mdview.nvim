--- Test helper: put the editor's tab pages, windows and buffers back the way
--- they were at the baseline (see below).
---
--- `:%bwipeout!` is not that: it also wipes the editor's own first buffer, so
--- Neovim creates a fresh `[No Name]` one, and it leaves split windows and tab
--- pages standing as long as they show some buffer. The state guard of
--- testing.nvim reports each of those as a leak of the case.
---
--- The baseline is taken when this module is first required and again by every
--- `snapshot()`. Describe bodies and cases run inline, in source order, so a
--- fixture made in a describe body (after the require) exists from that point on
--- and would be wiped by the first `restore()` against the require-time
--- baseline. Specs therefore take the baseline per case:
---
---   local ui_reset = require("TESTS.nvim.helpers.ui_reset")
---   before_each(ui_reset.snapshot)
---   after_each(ui_reset.restore)

local M = {}

---@param list integer[]
---@return table<integer, true>
local function set_of(list)
  local set = {}
  for _, v in ipairs(list) do
    set[v] = true
  end
  return set
end

local base_tabs, base_wins, base_bufs, base_tab, base_win, base_buf

--- Take the baseline: what exists now is kept by `restore()`.
function M.snapshot()
  base_tabs = set_of(vim.api.nvim_list_tabpages())
  base_wins = set_of(vim.api.nvim_list_wins())
  base_bufs = set_of(vim.api.nvim_list_bufs())
  base_tab = vim.api.nvim_get_current_tabpage()
  base_win = vim.api.nvim_get_current_win()
  base_buf = vim.api.nvim_win_get_buf(base_win)
end

M.snapshot()

--- Close every tab page and window made since the baseline, show the baseline
--- buffer in the baseline window again and wipe every buffer made since.
function M.restore()
  if vim.api.nvim_tabpage_is_valid(base_tab) then
    pcall(vim.api.nvim_set_current_tabpage, base_tab)
  end
  if vim.api.nvim_win_is_valid(base_win) then
    pcall(vim.api.nvim_set_current_win, base_win)
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not base_tabs[tab] and vim.api.nvim_tabpage_is_valid(tab) then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not base_wins[win] and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if vim.api.nvim_win_is_valid(base_win) and vim.api.nvim_buf_is_valid(base_buf) then
    pcall(vim.api.nvim_win_set_buf, base_win, base_buf)
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not base_bufs[buf] and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
