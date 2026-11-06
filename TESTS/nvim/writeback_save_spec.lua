---@module 'tests.nvim.writeback_save_spec'
-- A write-back from the preview is saved after a quiet time, once, and only when
-- what would go to disk came from the browser.

---@diagnostic disable: undefined-global

local inbound = require("mdview.adapter.inbound_poll")
local save = require("mdview.adapter.writeback_save")
local normalize = require("mdview.helper.normalize")
local config = require("mdview.config")
local live = require("mdview.bindings.autocmds.live_push")
local ws = require("mdview.adapter.ws_client")
local control = require("mdview.adapter.control")

local MS = 30
local ms0 = config.defaults.browser.write_back_save_debounce_ms
local ws_orig = { content = ws.send_content, doc = ws.send_doc, control = ws.send_control }
local control_orig = control.send
local notify_orig = vim.notify

---@type integer
local buf
---@type string
local path
---@type string
local key
---@type string[]
local told
---@type integer
local writes

---@return string[]
local function on_disk()
  return vim.fn.readfile(path)
end

--- Wait out the quiet time and a bit more.
local function settle()
  vim.wait(MS * 6, function()
    return false
  end, 5)
end

--- Tick the checkbox on line 1 from the preview, as the poll would.
---@param checked boolean
local function tick(checked)
  inbound._handle_toggle(key, 1, checked, nil, nil)
end

describe("mdview.adapter.writeback_save", function()
  before_each(function()
    config.defaults.browser.write_back_save_debounce_ms = MS
    path = (vim.fn.tempname() .. ".md"):gsub("\\", "/")
    vim.fn.writefile({ "- [ ] one", "- [ ] two" }, path)
    -- Loaded without becoming current: wiping it leaves no empty buffer behind, and
    -- a write-back has to work on a buffer no window shows anyway.
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("noautocmd setlocal filetype=markdown")
    end)
    key = assert(normalize.path(vim.api.nvim_buf_get_name(buf)))
    live._last_doc[key] = key
    told, writes = {}, 0
    ws.send_content = function() end
    ws.send_doc = function() end
    ws.send_control = function() end
    control.send = function(msg)
      told[#told + 1] = msg.notice
    end
    vim.notify = function() end
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = buf,
      callback = function()
        writes = writes + 1
      end,
    })
    inbound._set_last_key(0)
  end)

  after_each(function()
    save.flush()
    config.defaults.browser.write_back_save_debounce_ms = ms0
    ws.send_content, ws.send_doc, ws.send_control = ws_orig.content, ws_orig.doc, ws_orig.control
    control.send = control_orig
    vim.notify = notify_orig
    live._last_doc[key] = nil
    vim.cmd("bwipeout! " .. buf)
    vim.fn.delete(path)
  end)

  it("saves after the quiet time, and not before", function()
    tick(true)
    assert.equals("- [x] one", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.equals("- [ ] one", on_disk()[1])
    settle()
    assert.equals("- [x] one", on_disk()[1])
    assert.is_false(vim.bo[buf].modified)
  end)

  it("runs the write hooks as a normal save does, once for several write-backs", function()
    tick(true)
    tick(false)
    tick(true)
    settle()
    assert.equals(1, writes)
    assert.equals("- [x] one", on_disk()[1])
  end)

  it("leaves a buffer with unsaved changes from Neovim alone and tells the tab once", function()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "- [ ] half finished" })
    tick(true)
    tick(false)
    settle()
    assert.equals("- [ ] two", on_disk()[2])
    assert.is_true(vim.bo[buf].modified)
    assert.equals(1, #told)
    assert.is_truthy(told[1]:find("unsaved changes from Neovim", 1, true), told[1])
  end)

  it("does not save when the buffer is changed in Neovim during the quiet time", function()
    tick(true)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "- [ ] typed meanwhile" })
    settle()
    assert.equals("- [ ] one", on_disk()[1])
    assert.is_true(vim.bo[buf].modified)
    assert.is_truthy(told[1] and told[1]:find("changed in Neovim", 1, true), told[1])
  end)

  it("does nothing with the option at 0 or false", function()
    for _, off in ipairs({ 0, false }) do
      config.defaults.browser.write_back_save_debounce_ms = off
      tick(true)
      settle()
      assert.equals("- [ ] one", on_disk()[1])
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, on_disk())
      vim.bo[buf].modified = false
    end
    assert.equals(0, writes)
  end)

  it("does not create a file for a buffer that has none on disk yet", function()
    vim.fn.delete(path)
    tick(true)
    settle()
    assert.equals(0, vim.fn.filereadable(path))
    assert.is_true(vim.bo[buf].modified)
  end)

  it("does not save a read-only buffer", function()
    vim.bo[buf].readonly = true
    tick(true)
    settle()
    assert.equals("- [ ] one", on_disk()[1])
  end)

  it("does not overwrite a file changed on disk, and asks nothing", function()
    vim.fn.writefile({ "- [ ] from elsewhere" }, path)
    local later = os.time() + 120
    vim.uv.fs_utime(path, later, later)
    tick(true)
    settle()
    assert.equals("- [ ] from elsewhere", on_disk()[1])
    assert.is_true(vim.bo[buf].modified)
    assert.is_truthy(told[1] and told[1]:find("changed on disk", 1, true), told[1])
  end)

  it("reports a failed write to the tab instead of raising", function()
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = buf,
      once = true,
      callback = function()
        error("hook failed")
      end,
    })
    tick(true)
    settle()
    assert.equals("- [ ] one", on_disk()[1])
    assert.equals(1, #told)
    assert.is_truthy(told[1]:find("Not saved: ", 1, true), told[1])
  end)

  it("saves what is waiting when the session stops", function()
    config.defaults.browser.write_back_save_debounce_ms = 60000
    tick(true)
    assert.equals("- [ ] one", on_disk()[1])
    inbound.stop()
    assert.equals("- [x] one", on_disk()[1])
  end)

  it("is known as the debounced save while it writes, for the push on write", function()
    local during
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = buf,
      callback = function()
        during = save.is_saving(buf)
      end,
    })
    tick(true)
    settle()
    assert.is_true(during)
    assert.is_false(save.is_saving(buf))
    during = nil
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    assert.is_false(during)
  end)
end)
