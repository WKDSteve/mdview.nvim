---@module 'tests.nvim.relay_port_wait_spec'
-- Before the relay has announced its port, nothing asks it anything.
--
-- `:MDView start` spawns the relay and polls /health right away, but the port is
-- only known once the runner has read the relay's first line ("Running on
-- http://localhost:<port>"). The poll used to fall back to the default port
-- 43219 until then: with an own `server_port` that is a closed port (a refused
-- connect costs ~2 s per curl on Windows -- "the relay is up" took 2.8 s instead
-- of well under one), and with 43219 taken by another instance its relay
-- answered. The inbound poll did the same every 250 ms.
--
-- The process starter is a recorder: no curl runs, and the spec calls on_exit by
-- hand where an answer is wanted.

---@diagnostic disable: undefined-global, duplicate-set-field

local function fresh(name)
  local saved = package.loaded[name]
  package.loaded[name] = nil
  local mod = require(name)
  package.loaded[name] = saved
  return mod
end

--- Run `fn(calls)` with curl present, jobstart recording `{ argv, opts }`, the
--- messages muted and vim.g.mdview_server_port put back afterwards.
---@param fn fun(calls: { argv: string[], opts: table }[])
local function with_recorder(fn)
  local orig = {
    executable = vim.fn.executable,
    jobstart = vim.fn.jobstart,
    echo = vim.api.nvim_echo,
    notify = vim.notify,
    port = vim.g.mdview_server_port,
  }
  local calls = {}
  vim.fn.executable = function(name)
    if name == "curl" then
      return 1
    end
    return orig.executable(name)
  end
  vim.fn.jobstart = function(argv, opts)
    calls[#calls + 1] = { argv = argv, opts = opts }
    return 11
  end
  vim.api.nvim_echo = function() end
  vim.notify = function() end

  local ok, err = pcall(fn, calls)

  vim.fn.executable, vim.fn.jobstart = orig.executable, orig.jobstart
  vim.api.nvim_echo, vim.notify = orig.echo, orig.notify
  vim.g.mdview_server_port = orig.port
  if not ok then
    error(err, 0)
  end
end

describe("ws_client.wait_ready before the relay announced its port", function()
  it("starts no curl until the port is known, then asks that port and becomes ready", function()
    with_recorder(function(calls)
      local ws = fresh("mdview.adapter.ws_client")
      vim.g.mdview_server_port = nil
      local result = "pending"
      ws.wait_ready(function(ok)
        result = ok
      end, 5000)

      vim.wait(300, function()
        return #calls > 0
      end, 10)
      assert.are.equal(0, #calls, "a /health curl went out before the port was known: " .. vim.inspect(calls))
      assert.are.equal("pending", result)

      -- What the runner does once the relay printed its first line.
      vim.g.mdview_server_port = 43556
      vim.wait(1000, function()
        return #calls > 0
      end, 10)
      assert.are.equal(1, #calls)
      assert.are.equal("http://127.0.0.1:43556/health", calls[1].argv[#calls[1].argv])

      calls[1].opts.on_exit(11, 0)
      assert.is_true(result)
      assert.is_true(ws._ready)
    end)
  end)

  it("times out without a single curl when the port never comes", function()
    with_recorder(function(calls)
      local ws = fresh("mdview.adapter.ws_client")
      vim.g.mdview_server_port = nil
      local result = "pending"
      ws.wait_ready(function(ok)
        result = ok
      end, 120)

      vim.wait(2000, function()
        return result ~= "pending"
      end, 10)
      assert.is_false(result)
      assert.are.equal(0, #calls, "never ask the default port: " .. vim.inspect(calls))
    end)
  end)

  it("still fails at once when curl is missing", function()
    with_recorder(function(calls)
      local ws = fresh("mdview.adapter.ws_client")
      vim.g.mdview_server_port = nil
      local executable = vim.fn.executable
      vim.fn.executable = function(name)
        if name == "curl" then
          return 0
        end
        return executable(name)
      end
      local result = "pending"
      ws.wait_ready(function(ok)
        result = ok
      end, 5000)
      vim.fn.executable = executable
      assert.is_false(result)
      assert.are.equal(0, #calls)
    end)
  end)
end)

describe("runner.start_server", function()
  it("forgets the port of an earlier relay before it spawns the next one", function()
    with_recorder(function()
      local state = require("mdview.core.state")
      local orig_proc = state.get_proc()
      local orig_spawn = vim.uv.spawn
      state.set_proc(nil)
      vim.g.mdview_server_port = 43219
      vim.uv.spawn = function()
        return nil, nil, "spec: no process"
      end
      local ok, err = pcall(function()
        assert.is_nil(fresh("mdview.adapter.runner").start_server("mdview-server", {}, vim.fn.getcwd()))
      end)
      vim.uv.spawn = orig_spawn
      state.set_proc(orig_proc)
      assert(ok, err)
      assert.is_nil(vim.g.mdview_server_port)
    end)
  end)
end)

describe("inbound_poll before the relay announced its port", function()
  it("starts no curl, and polls the announced port once it is known", function()
    with_recorder(function(calls)
      local poll = fresh("mdview.adapter.inbound_poll")
      local state = require("mdview.core.state")
      local orig_server = state.get_server()
      state.set_server({ spec = true })
      vim.g.mdview_server_port = nil
      local ok, err = pcall(function()
        poll.start()
        vim.wait(800, function()
          return #calls > 0
        end, 20)
        assert.are.equal(0, #calls, "the inbound poll asked before the port was known: " .. vim.inspect(calls))

        vim.g.mdview_server_port = 43557
        vim.wait(1500, function()
          return #calls > 0
        end, 20)
        assert(#calls > 0, "no poll once the port was known")
        for _, c in ipairs(calls) do
          local url = c.argv[#c.argv]
          assert(url:find("http://127.0.0.1:43557/", 1, true) == 1, "polled " .. url)
        end
      end)
      poll.stop()
      state.set_server(orig_server)
      assert(ok, err)
    end)
  end)
end)
