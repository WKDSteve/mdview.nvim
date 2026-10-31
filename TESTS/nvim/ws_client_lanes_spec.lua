---@module 'tests.nvim.ws_client_lanes_spec'
-- Verifies the ordered lanes of mdview.adapter.ws_client: every POST is its own
-- curl process, and two processes started milliseconds apart reach the relay in
-- either order. Before the fix send_content and send_control started a curl per
-- push at once, so an older text could become the relay's LastPayload and a
-- stale `{"selection":false}` could land after the new selection. Now one room's
-- content (and its controls) has at most one curl in flight; the rest waits in
-- order, a full text replacing what it supersedes.
--
-- vim.fn.jobstart is stubbed: each started curl is recorded with its URL and
-- body (read from the temp file it posts), and the test decides when it exits.

---@diagnostic disable: undefined-global, duplicate-set-field

-- A private instance: line_diff_transport_spec.lua stubs ws.send_markdown on
-- the shared module while it runs, and this spec needs the real one.
local shared = package.loaded["mdview.adapter.ws_client"]
package.loaded["mdview.adapter.ws_client"] = nil
local ws = require("mdview.adapter.ws_client")
package.loaded["mdview.adapter.ws_client"] = shared

local config = require("mdview.config")

-- The failure cases report through notify; keep that out of the run's output
-- (this file runs in its own editor, isolated = "file").
local orig_echo, orig_notify = vim.api.nvim_echo, vim.notify
vim.api.nvim_echo = function() end
vim.notify = function() end
-- teardown() at the top level runs once every block of this file is done (also when one
-- raises), so the silenced output stays silenced for every case below.
teardown(function()
  vim.api.nvim_echo, vim.notify = orig_echo, orig_notify
end)

local A = "C:/spec/lanes/a.md"
local B = "C:/spec/lanes/b.md"

local orig_jobstart, orig_executable = vim.fn.jobstart, vim.fn.executable
local orig_stall = ws.LANE_STALL_MS
--- Curls started so far: { url, body, opts, exited }.
local started

---@param cmd string[]
---@return string url, string body
local function url_and_body(cmd)
  local url, body = "", ""
  for i, part in ipairs(cmd) do
    if type(part) == "string" and part:match("^http://") then
      url = part
    elseif part == "--data-binary" then
      local f = io.open(cmd[i + 1]:sub(2), "rb")
      if f then
        body = f:read("*a")
        f:close()
      end
    end
  end
  return url, body
end

--- Let curl number `i` exit with `code` (default 0).
---@param i integer
---@param code integer|nil
local function finish(i, code)
  local job = started[i]
  assert(job, "no curl #" .. i .. " was started")
  assert(not job.exited, "curl #" .. i .. " already exited")
  job.exited = true
  job.opts.on_exit(i, code or 0, "exit")
end

---@param endpoint string
---@return string[] # the bodies posted to `endpoint`, in start order
local function bodies(endpoint)
  local out = {}
  for _, job in ipairs(started) do
    if job.url:find("/" .. endpoint .. "?", 1, true) then
      out[#out + 1] = job.body
    end
  end
  return out
end

local function stub_curl()
  started = {}
  ws.reset_lanes()
  ws.reset_diff_state()
  ws.LANE_STALL_MS = 60000
  config.defaults.experimental.line_diff = false
  vim.fn.executable = function(name)
    if name == "curl" then
      return 1
    end
    return orig_executable(name)
  end
  vim.fn.jobstart = function(cmd, opts)
    local url, body = url_and_body(cmd)
    started[#started + 1] = { url = url, body = body, opts = opts, exited = false }
    return #started
  end
end

local function unstub_curl()
  ws.reset_lanes()
  ws.reset_diff_state()
  ws.LANE_STALL_MS = orig_stall
  config.defaults.experimental.line_diff = false
  vim.fn.jobstart, vim.fn.executable = orig_jobstart, orig_executable
end

describe("ws_client content lane", function()
  before_each(stub_curl)
  after_each(unstub_curl)

  it("two quick send_content into one room reach the relay in that order", function()
    ws.send_content(A, { "patch" })
    ws.send_content(A, { "final" })
    assert.are.equal(1, #started, "the second push must wait for the first curl")
    finish(1)
    assert.are.same({ "patch", "final" }, bodies("update"))
  end)

  it("a burst is coalesced: the one in flight, then only the newest", function()
    ws.send_content(A, { "one" })
    ws.send_content(A, { "two" })
    ws.send_content(A, { "three" })
    finish(1)
    assert.are.same({ "one", "three" }, bodies("update"))
    finish(2)
    assert.are.equal(2, #started, "nothing left to send")
  end)

  it("rooms do not wait on each other", function()
    ws.send_content(A, { "a" })
    ws.send_content(B, { "b" })
    assert.are.same({ "a", "b" }, bodies("update"))
  end)

  it("a failed or unstartable curl does not hold the lane", function()
    ws.send_content(A, { "one" })
    ws.send_content(A, { "two" })
    finish(1, 7)
    assert.are.same({ "one", "two" }, bodies("update"))

    vim.fn.jobstart = function()
      return -1
    end
    finish(2)
    ws.send_content(A, { "lost" })
    vim.fn.jobstart = function(cmd, opts)
      local url, body = url_and_body(cmd)
      started[#started + 1] = { url = url, body = body, opts = opts, exited = false }
      return #started
    end
    ws.send_content(A, { "after" })
    assert.are.same({ "one", "two", "after" }, bodies("update"))
  end)

  it("a curl that never exits frees the lane after LANE_STALL_MS", function()
    ws.LANE_STALL_MS = 30
    ws.send_content(A, { "hung" })
    ws.send_content(A, { "next" })
    assert.are.equal(1, #started)
    assert.is_true(vim.wait(1000, function()
      return #started == 2
    end, 5))
    assert.are.same({ "hung", "next" }, bodies("update"))
    -- the late exit of the hung curl starts nothing a second time
    finish(1)
    assert.are.equal(2, #started)
  end)

  it("line_diff: a diff waits for the full it builds on", function()
    config.defaults.experimental.line_diff = true
    ws.send_content(A, { "x", "y" })
    ws.send_content(A, { "x", "Y" })
    assert.are.equal(1, #started)
    assert.is_truthy(started[1].url:find("/update?", 1, true))
    finish(1)
    assert.are.equal(2, #started)
    assert.is_truthy(started[2].url:find("/diff?", 1, true))
  end)
end)

describe("ws_client control lane", function()
  before_each(stub_curl)
  after_each(unstub_curl)

  it("a cleared selection cannot overtake the new one", function()
    ws.send_control(A, '{"selection":false}')
    ws.send_control(A, '{"selection":{"from":1,"to":3}}')
    assert.are.equal(1, #started)
    finish(1)
    assert.are.same({ '{"selection":false}', '{"selection":{"from":1,"to":3}}' }, bodies("control"))
  end)

  it("queued selections collapse to the newest, other controls are all sent in order", function()
    ws.send_control(A, '{"zoom":1.2}')
    ws.send_control(A, '{"selection":{"from":1,"to":1}}')
    ws.send_control(A, '{"cursor":"caret"}')
    ws.send_control(A, '{"selection":{"from":1,"to":2}}')
    finish(1)
    finish(2)
    finish(3)
    assert.are.same({
      '{"zoom":1.2}',
      '{"cursor":"caret"}',
      '{"selection":{"from":1,"to":2}}',
    }, bodies("control"))
  end)

  it("controls do not wait for the room's content", function()
    ws.send_content(A, { "text" })
    ws.send_control(A, '{"zoom":2}')
    assert.are.equal(2, #started)
  end)
end)

-- The retry queue of send_markdown (no `immediate`): an answer for an entry a
-- newer push has replaced belongs to that old entry only. Before the lanes the
-- success of the older post cleared the newer entry (so its failure was never
-- retried), and the failure of the older one re-sent the newer text twice.
describe("ws_client pending queue on the content lane", function()
  before_each(stub_curl)
  after_each(unstub_curl)

  it("the success of a superseded post leaves the newer entry pending", function()
    ws.send_markdown(A, "one")
    ws.send_markdown(A, "two")
    local newer = ws._pending[A]
    assert.is_truthy(newer)
    finish(1)
    assert.are.equal(newer, ws._pending[A], "the newer entry must stay queued until its own answer")
    finish(2)
    assert.is_nil(ws._pending[A])
    assert.are.same({ "one", "two" }, bodies("update"))
  end)

  it("the failure of a superseded post does not send the newer text again", function()
    ws.send_markdown(A, "one")
    ws.send_markdown(A, "two")
    finish(1, 7)
    -- longer than the first retry delay (base_retry_ms, 150 ms by default)
    vim.wait(400, function()
      return false
    end, 10)
    finish(2)
    vim.wait(50, function()
      return false
    end, 10)
    assert.are.same({ "one", "two" }, bodies("update"))
  end)
end)

-- The sidecar channels: /spans is stored by the relay and replayed to joining
-- tabs, /doc drives browser history, /scroll moves the tab. Before their lanes
-- each push started its own curl at once, so an older one could land last.
describe("ws_client spans, doc and scroll lanes", function()
  before_each(stub_curl)
  after_each(unstub_curl)

  it("spans: a newer payload cannot be overtaken, a queued one is superseded", function()
    ws.send_spans(A, '{"v":1}')
    ws.send_spans(A, '{"v":2}')
    ws.send_spans(A, nil)
    assert.are.equal(1, #started, "the second push must wait for the first curl")
    finish(1)
    assert.are.same({ '{"v":1}', "null" }, bodies("spans"))
  end)

  it("doc: every switch is sent, in order", function()
    ws.send_doc(A, "C:/x/one.md")
    ws.send_doc(A, "C:/x/two.md")
    ws.send_doc(A, "C:/x/three.md")
    assert.are.equal(1, #started)
    finish(1)
    finish(2)
    assert.are.same({ "C:/x/one.md", "C:/x/two.md", "C:/x/three.md" }, bodies("doc"))
  end)

  it("scroll: an older position cannot land after a newer one", function()
    ws.send_scroll(A, 1, 100)
    ws.send_scroll(A, 2, 100)
    ws.send_scroll(A, 3, 100)
    assert.are.equal(1, #started)
    finish(1)
    assert.are.same({ "1/100", "3/100" }, bodies("scroll"))
  end)

  it("the channels of one room do not wait on each other", function()
    ws.send_spans(A, "{}")
    ws.send_doc(A, "C:/x/one.md")
    ws.send_scroll(A, 1, 10)
    ws.send_content(A, { "text" })
    assert.are.equal(4, #started)
  end)
end)
