---@module 'tests.nvim.relay_host_spec'
-- Every request of the transport goes to 127.0.0.1, never to `localhost`.
--
-- The relay listens on 127.0.0.1 only. With `localhost` in the URL curl tries
-- `::1` first, and on Windows the refused IPv6 connect costs ~200 ms before it
-- falls back: each curl took ~210 ms instead of ~2 ms, and the blocking ones
-- (:MDView stop's /close, the shared relay's /attach probe and /detach) froze
-- the editor that long (testing perf, 2026-11-19 and 2026-11-21). Those three no
-- longer start curl at all: relay_http_spec.lua.
--
-- Each case calls one entry point with the process starters replaced by
-- recorders (vim.fn.jobstart / vim.fn.system) and checks the URL in the argv.
-- Nothing is started and no callback is called: only the argv matters.

---@diagnostic disable: undefined-global, duplicate-set-field

-- Private instances: other specs replace functions on the shared modules.
local function fresh(name)
  local saved = package.loaded[name]
  package.loaded[name] = nil
  local mod = require(name)
  package.loaded[name] = saved
  return mod
end

local PORT = 43555

--- The URL arguments (http://...) of every recorded argv.
---@param calls string[][]
---@return string[]
local function urls_of(calls)
  local out = {}
  for _, argv in ipairs(calls) do
    for _, a in ipairs(argv) do
      if type(a) == "string" and a:find("^https?://") then
        out[#out + 1] = a
      end
    end
  end
  return out
end

--- Run `fn` with curl present and both process starters recording; returns the URLs they were given.
---@param fn fun()
---@return string[]
local function recorded_urls(fn)
  local orig = {
    executable = vim.fn.executable,
    jobstart = vim.fn.jobstart,
    system = vim.fn.system,
    port = vim.g.mdview_server_port,
  }
  local state = require("mdview.core.state")
  local orig_token = state.get_token()
  local calls = {}
  vim.fn.executable = function(name)
    if name == "curl" then
      return 1
    end
    return orig.executable(name)
  end
  vim.fn.jobstart = function(argv)
    calls[#calls + 1] = argv
    return 7
  end
  vim.fn.system = function(argv)
    calls[#calls + 1] = argv
    return ""
  end
  vim.g.mdview_server_port = PORT
  state.set_token("spec-token")

  local ok, err = pcall(fn)

  vim.fn.executable, vim.fn.jobstart, vim.fn.system = orig.executable, orig.jobstart, orig.system
  vim.g.mdview_server_port = orig.port
  state.set_token(orig_token)
  if not ok then
    error(err, 0)
  end
  return urls_of(calls)
end

--- Assert that `urls` is not empty and that each one names 127.0.0.1 and the port.
---@param urls string[]
---@param what string
local function assert_loopback_v4(urls, what)
  assert(#urls > 0, what .. ": no request was recorded")
  for _, url in ipairs(urls) do
    assert(
      url:find("http://127.0.0.1:" .. PORT .. "/", 1, true) == 1,
      what .. " must go to http://127.0.0.1:" .. PORT .. "/, got " .. url
    )
  end
end

describe("relay_url", function()
  it("builds the base URL on the IPv4 loopback address", function()
    assert.are.equal("http://127.0.0.1:43219", require("mdview.adapter.relay_url").base(43219))
  end)
end)

describe("every relay request of the transport names 127.0.0.1", function()
  it("ws_client: the /health poll", function()
    local ws = fresh("mdview.adapter.ws_client")
    assert_loopback_v4(
      recorded_urls(function()
        ws.reset_ready()
        ws.wait_ready(function() end, 50)
      end),
      "/health"
    )
  end)

  it("ws_client: a content push (/update)", function()
    local ws = fresh("mdview.adapter.ws_client")
    assert_loopback_v4(
      recorded_urls(function()
        ws.send_markdown("C:/spec/host.md", "# host", { immediate = true })
      end),
      "/update"
    )
  end)

  it("ws_client: /spotlight, /keys and the /attach status", function()
    local ws = fresh("mdview.adapter.ws_client")
    assert_loopback_v4(
      recorded_urls(function()
        ws.send_spotlight('{"spots":[]}')
        ws.send_keys('{"text":"x"}')
        ws.tab_rooms(function() end)
      end),
      "spotlight/keys/attach"
    )
  end)

  it("inbound_poll: the write-back polls", function()
    local poll = fresh("mdview.adapter.inbound_poll")
    local state = require("mdview.core.state")
    local orig_server = state.get_server()
    local urls = recorded_urls(function()
      state.set_server({ spec = true })
      poll.start()
      vim.wait(2000, function()
        return false
      end, 50)
      poll.stop()
    end)
    state.set_server(orig_server)
    assert_loopback_v4(urls, "inbound poll")
  end)

  it("shared_relay: the /attach probe of discover()", function()
    local shared = fresh("mdview.adapter.shared_relay")
    shared.read_discovery = function()
      return { port = PORT, token = "spec-token" }
    end
    local probed = {}
    shared._probe = function(url)
      probed[#probed + 1] = url
      return nil
    end
    local urls = recorded_urls(function()
      shared.discover()
    end)
    vim.list_extend(urls, probed)
    assert.are.equal(1, #urls, "expected the probe, got " .. vim.inspect(urls))
    assert_loopback_v4(urls, "shared relay")
  end)
end)

describe("the adapter sources", function()
  it("name no localhost URL outside comments and the runner's output patterns", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
    local files = vim.fn.globpath(root .. "/lua/mdview/adapter", "**/*.lua", false, true)
    assert(#files > 5, "expected the adapter sources under " .. root)
    local offenders = {}
    for _, file in ipairs(files) do
      for lnum, line in ipairs(vim.fn.readfile(file)) do
        local code = line:match("^%s*%-%-") and "" or line
        if code:find("localhost", 1, true) and not code:find(":match(", 1, true) then
          offenders[#offenders + 1] = ("%s:%d: %s"):format(vim.fn.fnamemodify(file, ":t"), lnum, vim.trim(line))
        end
      end
    end
    assert.are.same({}, offenders)
  end)
end)
