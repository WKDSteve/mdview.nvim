---@module 'tests.nvim.relay_http_spec'
-- The requests that must finish before the caller goes on -- :MDView stop's
-- /close, the shared relay's /detach and its /attach probe on :MDView start --
-- go over a loopback TCP connection, not through a curl process.
--
-- With curl each of them was a process start on the editor thread: on Windows
-- 150-450 ms under load (testing perf 2026-11-21: /close 168-631 ms, /attach
-- 354-387 ms, /detach 308-448 ms), even with the relay answering in 2 ms.
--
-- The relay is a fixture: a TCP server of this Neovim on 127.0.0.1, port 0 (the
-- system picks one), answering like Go's net/http. Every process starter throws,
-- so a fallback to curl fails the case. The cases that connect carry the tag
-- @network (testing.nvim's process_net guard); the fixture binds 127.0.0.1 only.

---@diagnostic disable: undefined-global, duplicate-set-field

local uv = vim.uv or vim.loop

local function fresh(name)
  local saved = package.loaded[name]
  package.loaded[name] = nil
  local mod = require(name)
  package.loaded[name] = saved
  return mod
end

--- A one-request-per-connection HTTP fixture on 127.0.0.1. `answer(request)`
--- returns the raw response, or nil to never answer (the timeout case).
---@param answer fun(request: string): string|nil
---@return { port: integer, requests: string[], close: fun() }
local function fixture(answer)
  local server = assert(uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  local requests = {}
  local clients = {}
  assert(server:listen(8, function(err)
    assert(not err, err)
    local client = assert(uv.new_tcp())
    clients[#clients + 1] = client
    server:accept(client)
    local got = ""
    client:read_start(function(read_err, data)
      if read_err or not data then
        return
      end
      got = got .. data
      if got:find("\r\n\r\n", 1, true) then
        requests[#requests + 1] = got
        local response = answer(got)
        if response then
          client:write(response, function()
            client:close()
          end)
        end
      end
    end)
  end))
  return {
    port = server:getsockname().port,
    requests = requests,
    close = function()
      for _, c in ipairs(clients) do
        if not c:is_closing() then
          c:close()
        end
      end
      server:close()
    end,
  }
end

local function ok_answer(body)
  return function()
    return "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n" .. body
  end
end

--- Run `fn` with every process starter throwing and the session's token and port set.
---@param port integer
---@param fn fun()
local function without_processes(port, fn)
  local orig = {
    system = vim.fn.system,
    jobstart = vim.fn.jobstart,
    vsystem = vim.system,
    port = vim.g.mdview_server_port,
  }
  local state = require("mdview.core.state")
  local orig_token = state.get_token()
  local function no_process()
    error("a request that must finish first started a process (curl)")
  end
  vim.fn.system, vim.fn.jobstart, vim.system = no_process, no_process, no_process
  vim.g.mdview_server_port = port
  state.set_token("spec-token")

  local ok, err = pcall(fn)

  vim.fn.system, vim.fn.jobstart, vim.system = orig.system, orig.jobstart, orig.vsystem
  vim.g.mdview_server_port = orig.port
  state.set_token(orig_token)
  if not ok then
    error(err, 0)
  end
end

describe("relay_http.request_sync", function()
  it("sends one HTTP request to 127.0.0.1 and returns the body @network", function()
    local relay = fixture(ok_answer('{"shared":true}'))
    local body, err = require("mdview.adapter.relay_http").request_sync(relay.port, "GET", "/attach?token=t", 2000)
    relay.close()
    assert.is_nil(err)
    assert.are.equal('{"shared":true}', body)
    assert.are.equal(1, #relay.requests)
    assert(relay.requests[1]:find("^GET /attach%?token=t HTTP/1%.0\r\n"), relay.requests[1])
    assert(relay.requests[1]:find("\r\nHost: 127.0.0.1:" .. relay.port .. "\r\n", 1, true), relay.requests[1])
  end)

  it("returns nil and a reason when nothing answers in time @network", function()
    local relay = fixture(function()
      return nil
    end)
    local started = uv.hrtime()
    local body, err = require("mdview.adapter.relay_http").request_sync(relay.port, "POST", "/close?token=t", 150)
    local waited_ms = (uv.hrtime() - started) / 1e6
    relay.close()
    assert.is_nil(body)
    assert(err and err:find("timeout", 1, true), tostring(err))
    assert(waited_ms < 1000, "waited " .. waited_ms .. " ms")
  end)

  it("returns nil when the answer is no HTTP @network", function()
    local relay = fixture(function()
      return "garbage"
    end)
    local body, err = require("mdview.adapter.relay_http").request_sync(relay.port, "GET", "/health", 2000)
    relay.close()
    assert.is_nil(body)
    assert.are.equal("no HTTP answer", err)
  end)
end)

describe("the requests that must finish first start no process", function()
  it("ws_client.send_close posts /close to the relay and waits for it @network", function()
    local relay = fixture(ok_answer(""))
    without_processes(relay.port, function()
      fresh("mdview.adapter.ws_client").send_close()
    end)
    relay.close()
    assert.are.equal(1, #relay.requests, "the relay got no /close")
    assert(relay.requests[1]:find("^POST /close%?token=spec%-token HTTP/1%.0\r\n"), relay.requests[1])
  end)

  it("ws_client.send_close asks nothing while the relay has not announced its port", function()
    without_processes(43219, function()
      vim.g.mdview_server_port = nil
      local relay_http = require("mdview.adapter.relay_http")
      local orig = relay_http.request_sync
      local asked = 0
      relay_http.request_sync = function()
        asked = asked + 1
      end
      fresh("mdview.adapter.ws_client").send_close()
      relay_http.request_sync = orig
      assert.are.equal(0, asked)
    end)
  end)

  it("shared_relay.detach posts /detach with this instance's id @network", function()
    local relay = fixture(ok_answer(""))
    without_processes(relay.port, function()
      local shared = fresh("mdview.adapter.shared_relay")
      shared._attached = true
      shared.detach()
    end)
    relay.close()
    assert.are.equal(1, #relay.requests, "the relay got no /detach")
    assert(relay.requests[1]:find("^POST /detach%?token=spec%-token&client="), relay.requests[1])
  end)

  it("shared_relay.discover probes /attach and attaches to the answering relay @network", function()
    local shared = fresh("mdview.adapter.shared_relay")
    local relay = fixture(ok_answer(vim.json.encode({ shared = true, protocol = shared.PROTOCOL, tabs = {} })))
    local info, why
    without_processes(relay.port, function()
      shared.read_discovery = function()
        return { port = relay.port, token = "spec-token" }
      end
      info, why = shared.discover()
    end)
    relay.close()
    assert(info, "no relay found: " .. tostring(why))
    assert.are.equal(relay.port, info.port)
    assert(relay.requests[1]:find("^GET /attach%?token=spec%-token&client="), relay.requests[1])
  end)
end)
