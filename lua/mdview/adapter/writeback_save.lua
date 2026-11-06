---@module 'mdview.adapter.writeback_save'
-- Saves a buffer some time after a write-back from the preview (checkbox, text
-- field, block edit), so that working only in the browser does not leave the
-- file behind. `browser.write_back_save_debounce_ms` is the quiet time; each new
-- write-back for the buffer starts it again, and 0 or false turns this off.
--
-- Only what came from the browser goes to disk. A buffer that already had
-- unsaved changes from Neovim stays modified and the tab is told, so that half
-- finished edits are never written unasked. The check is against `changedtick`:
-- the buffer is modified by the write-backs themselves, and only a tick other
-- than the one the last write-back left means someone else changed it.
--
-- A buffer with no file on disk yet is not saved either: a write-back does not
-- create a file nobody has written.

local M = {}

local PREFIX = "Not saved: "

---@class mdview.WritebackSave.State
---@field tick integer|nil # `changedtick` after the last write-back; nil when no save is pending
---@field key string|nil # the room of the tab that sent the last write-back
---@field told boolean|nil # the tab has heard why this buffer is not saved

---@type table<integer, mdview.WritebackSave.State>
local states = {}

-- The buffer being saved right now, for `is_saving`.
---@type integer|nil
local saving

---@type Lib.Debounce.BufferHandle|nil
local debouncer
---@type integer|nil
local debouncer_ms

---@return integer # milliseconds; 0 is off
local function quiet_ms()
  local browser = require("mdview.config").defaults.browser
  local ms = type(browser) == "table" and browser.write_back_save_debounce_ms or 0
  return type(ms) == "number" and ms > 0 and ms or 0
end

---@param key string|nil
---@param message string
---@return nil
local function tell(key, message)
  require("lib.nvim.notify").create("").notify("[mdview] " .. PREFIX .. message, vim.log.levels.WARN)
  require("mdview.helper.log").debug(PREFIX .. message, nil, "writeback", true)
  if key then
    pcall(require("mdview.adapter.control").send, { notice = PREFIX .. message }, key)
  end
end

--- A buffer this feature may write at all.
---@param buf integer
---@return boolean
local function can_save(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local bo = vim.bo[buf]
  if bo.buftype ~= "" or bo.readonly or not bo.modifiable then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fn.filereadable(name) == 1
end

--- Whether the file on disk changed since the buffer read it. `:update` would
--- stop at a y/n prompt for that, and asking first is the only way to avoid it:
--- with a `FileChangedShell` autocmd in place `:checktime` only reports.
---@param buf integer
---@return boolean
local function changed_on_disk(buf)
  local changed = false
  local id = vim.api.nvim_create_autocmd("FileChangedShell", {
    buffer = buf,
    once = true,
    callback = function()
      changed = true
    end,
  })
  pcall(vim.cmd.checktime, buf)
  pcall(vim.api.nvim_del_autocmd, id)
  return changed
end

---@param buf integer
---@return nil
local function save(buf)
  local state = states[buf]
  if not state or not state.tick then
    return
  end
  local key, tick = state.key, state.tick
  state.tick = nil
  if not can_save(buf) then
    return
  end
  if not vim.bo[buf].modified then
    return
  end
  if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
    state.told = true
    tell(key, "the buffer was changed in Neovim since, so it stays modified")
    return
  end
  if changed_on_disk(buf) then
    state.told = true
    tell(key, "the file changed on disk, so the buffer stays modified")
    return
  end

  saving = buf
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent update")
  end)
  saving = nil
  if not ok then
    tell(key, tostring(err))
    return
  end
  -- A BufWritePre hook (a formatter) changed the text: the preview has not seen
  -- that, and `is_saving` kept the usual push on write from telling it.
  if vim.api.nvim_buf_get_changedtick(buf) ~= tick and key then
    local live = require("mdview.bindings.autocmds.live_push")
    pcall(live.push_buffer_changes, buf, { full = true })
  end
end

---@param ms integer
---@return Lib.Debounce.BufferHandle
local function debouncer_for(ms)
  if not debouncer or debouncer_ms ~= ms then
    if debouncer then
      debouncer.cancel_all()
    end
    debouncer = require("lib.nvim.debounce.buffer").new(save, { ms = ms })
    debouncer_ms = ms
  end
  return debouncer
end

--- Call before a write-back changes `buf`: does it hold changes from Neovim?
---@param buf integer
---@return boolean
function M.has_foreign_changes(buf)
  if not vim.bo[buf].modified then
    return false
  end
  local state = states[buf]
  return not (state and state.tick == vim.api.nvim_buf_get_changedtick(buf))
end

--- Call after a write-back changed `buf`.
---@param buf integer
---@param key string # the room of the tab that sent it
---@param foreign boolean # what `has_foreign_changes` said before the change
---@return nil
function M.note(buf, key, foreign)
  local ms = quiet_ms()
  if ms == 0 or not can_save(buf) then
    return
  end
  local state = states[buf] or {}
  states[buf] = state
  if foreign then
    state.tick = nil
    if debouncer then
      debouncer.cancel(buf)
    end
    if not state.told then
      state.told = true
      tell(key, "the buffer has unsaved changes from Neovim, so it stays modified")
    end
    return
  end
  state.told = nil
  state.key = key
  state.tick = vim.api.nvim_buf_get_changedtick(buf)
  debouncer_for(ms).call(buf)
end

--- Is this write the debounced save? The push on write stays away from it: the
--- preview already shows this text, and a re-render could take a field the
--- person is typing in away from them.
---@param buf integer
---@return boolean
function M.is_saving(buf)
  return saving == buf
end

--- Save everything still waiting and forget the rest: `:MDView stop` and leaving
--- Neovim. The changes came from the browser and were meant to be kept.
---@return nil
function M.flush()
  if debouncer then
    debouncer.cancel_all()
  end
  local pending = states
  states = {}
  for buf, state in pairs(pending) do
    if state.tick then
      states[buf] = state
      pcall(save, buf)
      states[buf] = nil
    end
  end
end

return M
