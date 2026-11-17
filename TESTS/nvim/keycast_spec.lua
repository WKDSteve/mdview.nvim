---@module 'tests.nvim.keycast_spec'
-- Covers the Neovim half of the keycast overlay up to the transport: the
-- `:MDView overlay keycast` switch and the session lifecycle in, the
-- subscription to ui.screenkey (stubbed: ui.nvim is not a dependency of this
-- suite) and the batches handed to ws_client.send_keys out. The capture itself
-- -- scopes, the protection of password input, vim.on_key only while
-- subscribed -- is ui.nvim's and covered by its TESTS/screenkey_subscribe_spec.lua.
-- The relay route is native/server/keys_test.go, the pill
-- TESTS/client/keycastOverlay.dom.test.ts.

---@diagnostic disable: undefined-global, need-check-nil, duplicate-set-field

local keycast = require("mdview.core.keycast")
local overlay = require("mdview.bindings.usrcmds.overlay")
local ws = require("mdview.adapter.ws_client")
local control = require("mdview.adapter.control")
local state = require("mdview.core.state")
local bcfg = require("mdview.config.browser")

local original_screenkey = package.loaded["ui.screenkey"]
local original_send_keys = ws.send_keys
local original_control_send = control.send
local original_notify = vim.notify
local original_batch, original_idle = keycast.BATCH_MS, keycast.IDLE_MS

-- What the stubbed ui.screenkey was asked, and what reached the stubbed relay.
local subscriptions, sent, msgs

--- A stand-in of ui.screenkey with subscribe(): each subscription records its
--- scope, can be fed keys by the test and formats them as "a b c".
local function install_screenkey()
  package.loaded["ui.screenkey"] = {
    subscribe = function(cb, opts)
      local sub = { scope = opts and opts.scope, live = true, keys = {} }
      function sub:text()
        return table.concat(self.keys, " ")
      end
      function sub:clear()
        self.keys = {}
      end
      function sub:unsubscribe()
        self.live = false
      end
      function sub:press(key)
        self.keys[#self.keys + 1] = key
        cb({ key = key, label = key, count = 1 }, self)
      end
      subscriptions[#subscriptions + 1] = sub
      return sub
    end,
  }
end

local function live()
  local out = {}
  for _, s in ipairs(subscriptions) do
    if s.live then
      out[#out + 1] = s
    end
  end
  return out
end

before_each(function()
  subscriptions, sent, msgs = {}, {}, {}
  install_screenkey()
  ws.send_keys = function(json)
    sent[#sent + 1] = vim.json.decode(json)
  end
  control.send = function()
    return true
  end
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg = msg, level = level }
  end
  keycast.BATCH_MS, keycast.IDLE_MS = 20, 200
  bcfg.defaults.overlays = { toc = false, keycast = false }
  bcfg.defaults.keycast = { scope = "normal" }
  state.set_server(nil)
end)

after_each(function()
  keycast.session_ended()
  package.loaded["ui.screenkey"] = original_screenkey
  ws.send_keys = original_send_keys
  control.send = original_control_send
  vim.notify = original_notify
  keycast.BATCH_MS, keycast.IDLE_MS = original_batch, original_idle
  bcfg.defaults.overlays = { toc = false, keycast = false }
  bcfg.defaults.keycast = { scope = "normal" }
  state.set_server(nil)
end)

describe("keycast overlay switch", function()
  it("is off by default and captures nothing", function()
    keycast.session_started()
    assert.is_false(keycast.is_active())
    assert.are.equal(0, #subscriptions)
  end)

  it("captures only while the overlay is on and a session runs", function()
    overlay.run("keycast", "on")
    assert.is_true(bcfg.defaults.overlays.keycast)
    assert.are.equal(0, #subscriptions, "no session: the choice waits, nothing is attached")

    keycast.session_started()
    assert.are.equal(1, #live())
    assert.are.equal("normal", live()[1].scope, "the default scope is normal")

    overlay.run("keycast", "off")
    assert.are.equal(0, #live(), "switching it off detaches the capture")

    overlay.run("keycast", "toggle")
    assert.are.equal(1, #live(), "and on again during the session")

    keycast.session_ended()
    assert.are.equal(0, #live(), "the session's teardown detaches it")
  end)

  it("takes the configured scope, and warns about one it does not know", function()
    bcfg.defaults.overlays.keycast = true
    bcfg.defaults.keycast = { scope = "insert_protected" }
    keycast.session_started()
    assert.are.equal("insert_protected", live()[1].scope)
    keycast.session_ended()

    bcfg.defaults.keycast = { scope = "insert" }
    keycast.session_started()
    assert.are.equal("normal", live()[1].scope)
    assert.truthy(msgs[#msgs].msg:find("browser.keycast.scope must be one of", 1, true))
    assert.are.equal(vim.log.levels.WARN, msgs[#msgs].level)
  end)

  it("reports itself unavailable without ui.screenkey.subscribe and stays off", function()
    package.loaded["ui.screenkey"] = {} -- a ui.nvim from before the API
    keycast.session_started()
    overlay.run("keycast", "on")
    assert.is_false(bcfg.defaults.overlays.keycast)
    assert.is_false(keycast.is_active())
    assert.truthy(msgs[#msgs].msg:find("overlay keycast is unavailable: this ui.nvim has no", 1, true), msgs[#msgs].msg)

    package.loaded["ui.screenkey"] = nil
    local loaders = package.loaders or package.searchers
    table.insert(loaders, 1, function(name)
      if name == "ui.screenkey" then
        return function()
          error("not installed")
        end
      end
    end)
    local ok, reason = keycast.available()
    table.remove(loaders, 1)
    assert.is_false(ok)
    assert.are.equal("ui.nvim is not installed", reason)
  end)

  it("on from setup() without ui.nvim: the session starts, says why nothing is captured", function()
    package.loaded["ui.screenkey"] = {}
    bcfg.defaults.overlays.keycast = true
    keycast.session_started()
    assert.is_false(keycast.is_active())
    assert.truthy(msgs[#msgs].msg:find("overlay keycast is unavailable: this ui.nvim has no", 1, true), msgs[#msgs].msg)
    assert.are.equal(vim.log.levels.WARN, msgs[#msgs].level)
  end)

  it("a subscribe() that raises does not break the session start", function()
    package.loaded["ui.screenkey"] = {
      subscribe = function()
        error("boom")
      end,
    }
    bcfg.defaults.overlays.keycast = true
    assert.has_no.errors(keycast.session_started)
    assert.is_false(keycast.is_active())
    assert.truthy(msgs[#msgs].msg:find("ui.screenkey.subscribe failed:", 1, true), msgs[#msgs].msg)
  end)
end)

describe("keycast batches", function()
  before_each(function()
    bcfg.defaults.overlays.keycast = true
    keycast.session_started()
  end)

  it("sends one batch per burst with the whole line, not one request per key", function()
    state.set_server({ stub = true })
    local sub = live()[1]
    sub:press(":")
    sub:press("w")
    sub:press("<CR>")
    vim.wait(500, function()
      return #sent > 0
    end, 5)
    vim.wait(60)
    assert.are.same({ { text = ": w <CR>" } }, sent)

    sub:press("j")
    vim.wait(500, function()
      return #sent > 1
    end, 5)
    assert.are.same({ text = ": w <CR> j" }, sent[2])
  end)

  it("starts the line over after a pause", function()
    state.set_server({ stub = true })
    local sub = live()[1]
    sub:press("j")
    vim.wait(keycast.IDLE_MS * 3, function()
      return #sub.keys == 0
    end, 5)
    assert.are.same({}, sub.keys)
  end)

  it("a relay that refuses the keys (one older than /keys) is reported once per session", function()
    state.set_server({ stub = true })
    ws.send_keys = function(json, cb)
      sent[#sent + 1] = vim.json.decode(json)
      cb(false, "404 page not found")
    end
    local sub = live()[1]
    local function refusals()
      local n = 0
      for _, m in ipairs(msgs) do
        if m.msg:find("keycast: the relay did not take the keys (404 page not found)", 1, true) then
          n = n + 1
        end
      end
      return n
    end
    sub:press("j")
    vim.wait(500, function()
      return refusals() == 1
    end, 5)
    sub:press("k")
    vim.wait(500, function()
      return #sent == 2
    end, 5)
    vim.wait(50)
    assert.are.equal(1, refusals(), "said once, not per batch")
    assert.are.equal(vim.log.levels.WARN, msgs[#msgs].level)

    keycast.session_ended()
    keycast.session_started() -- a new session says it again
    live()[1]:press("l")
    vim.wait(500, function()
      return refusals() == 2
    end, 5)
    assert.are.equal(2, refusals())
  end)

  it("sends nothing without a running relay", function()
    local sub = live()[1]
    sub:press("j")
    vim.wait(100)
    assert.are.same({}, sent)
  end)
end)
