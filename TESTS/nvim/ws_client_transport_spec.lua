---@module 'tests.nvim.ws_client_transport_spec'
-- Verifies the transport-level failure paths of mdview.adapter.ws_client that
-- need no relay: what happens when curl is missing. Before the fix both the
-- health poll and the POST fell back to a shell string (`sh -c "curl ..."`)
-- whose exit status was never read, so a missing curl was reported as a
-- SUCCESSFUL request -- wait_ready marked a dead relay ready and the pending
-- queue dropped the buffer content as "sent". The POST fallback also fed the
-- buffer text through a shell.
--
-- vim.fn.executable / vim.fn.system / vim.fn.jobstart are Neovim globals, so
-- they are stubbed directly (same pattern as health_spec.lua); vim.api.nvim_echo
-- is stubbed to capture the user-facing message instead of printing it.

---@diagnostic disable: undefined-global, duplicate-set-field

-- A private instance: line_diff_transport_spec.lua replaces ws.send_markdown
-- on the shared module for the rest of the run, and this spec needs the real
-- one. The shared instance is put back so nothing else notices.
local shared = package.loaded["mdview.adapter.ws_client"]
package.loaded["mdview.adapter.ws_client"] = nil
local ws = require("mdview.adapter.ws_client")
package.loaded["mdview.adapter.ws_client"] = shared

--- Run `fn` with curl reported as missing and every subprocess entry point
--- armed to fail the test if reached.
---@param fn fun(echoed: string[])
local function without_curl(fn)
  local orig_executable, orig_system, orig_jobstart, orig_echo =
    vim.fn.executable, vim.fn.system, vim.fn.jobstart, vim.api.nvim_echo
  local echoed = {}
  vim.fn.executable = function(name)
    if name == "curl" then
      return 0
    end
    return orig_executable(name)
  end
  vim.fn.system = function()
    error("vim.fn.system must not be reached without curl")
  end
  vim.fn.jobstart = function()
    error("vim.fn.jobstart must not be reached without curl")
  end
  vim.api.nvim_echo = function(chunks)
    for _, chunk in ipairs(chunks) do
      echoed[#echoed + 1] = chunk[1]
    end
  end

  local ok, err = pcall(fn, echoed)

  vim.fn.executable, vim.fn.system, vim.fn.jobstart, vim.api.nvim_echo =
    orig_executable, orig_system, orig_jobstart, orig_echo
  if not ok then
    error(err, 0)
  end
end

describe("ws_client.wait_ready without curl", function()
  it("fails at once with cb(false) instead of reporting the relay ready", function()
    without_curl(function(echoed)
      ws.reset_ready()
      local result = "not called"
      ws.wait_ready(function(ok)
        result = ok
      end, 100)

      assert.is_false(result)
      assert.is_false(ws._ready)
      assert(
        #echoed > 0 and echoed[1]:find("curl not found", 1, true),
        "expected the missing-curl message to be echoed"
      )
    end)
  end)
end)

describe("ws_client.send_markdown without curl", function()
  it("reports the missing curl as a failed POST and never touches a shell", function()
    without_curl(function(echoed)
      ws.send_markdown("C:/spec/no-curl.md", "$(rm -rf ~) `id`", { immediate = true })
      -- the failure notice is scheduled, not echoed inline
      vim.wait(200, function()
        return #echoed > 0
      end)
      assert(#echoed > 0, "expected a failure message")
      assert(echoed[1]:find("curl not found", 1, true), "expected the missing-curl reason, got: " .. echoed[1])
    end)
  end)
end)

--- Run `fn` with curl reported present but jobstart answering `start` (a value
--- returned, or a function that throws). `args` collects the argv jobstart got.
---@param start any|fun(): any
---@param fn fun(args: string[][])
local function with_failing_jobstart(start, fn)
  local orig_executable, orig_jobstart = vim.fn.executable, vim.fn.jobstart
  local args = {}
  vim.fn.executable = function(name)
    if name == "curl" then
      return 1
    end
    return orig_executable(name)
  end
  vim.fn.jobstart = function(argv)
    args[#args + 1] = argv
    if type(start) == "function" then
      return start()
    end
    return start
  end

  local ok, err = pcall(fn, args)

  vim.fn.executable, vim.fn.jobstart = orig_executable, orig_jobstart
  if not ok then
    error(err, 0)
  end
end

--- The argument after `--data-binary` in a POST's argv: `@-` (stdin) when nothing goes through a file.
---@param argv string[]
---@return string
local function body_source_of(argv)
  for i, a in ipairs(argv) do
    if a == "--data-binary" then
      return argv[i + 1]
    end
  end
  error("no --data-binary in " .. vim.inspect(argv))
end

describe("ws_client.send_spotlight when curl cannot be started", function()
  local cases = {
    { "returns -1", -1 },
    { "returns 0", 0 },
    {
      "throws",
      function()
        error("E475: Invalid value for argument cmd: 'curl' is not executable")
      end,
    },
  }

  for _, case in ipairs(cases) do
    it("answers cb(false, ...) at once when jobstart " .. case[1], function()
      with_failing_jobstart(case[2], function(args)
        local got
        ws.send_spotlight('{"type":"spotlight"}', function(ok, err)
          got = { ok, err }
        end)

        assert.is_table(got, "the callback must not be left waiting for an on_exit that never comes")
        assert.is_false(got[1])
        assert(tostring(got[2]):find("could not start curl", 1, true), "unexpected detail: " .. tostring(got[2]))
        assert.are.equal(1, #args)
        assert.are.equal("@-", body_source_of(args[1]), "the body goes over stdin, not into a file")
      end)
    end)
  end

  it("still reports a started job's exit through the callback", function()
    with_failing_jobstart(7, function()
      local got
      ws.send_spotlight('{"type":"spotlight"}', function(ok)
        got = ok
      end)
      assert.is_nil(got) -- 7 is a valid job id: the answer comes with on_exit
    end)
  end)
end)

describe("ws_client.wait_ready when curl cannot be started", function()
  it("gives up with cb(false) after the timeout instead of waiting for ever", function()
    with_failing_jobstart(-1, function()
      ws.reset_ready()
      local result = "not called"
      ws.wait_ready(function(ok)
        result = ok
      end, 60)
      vim.wait(2000, function()
        return result ~= "not called"
      end, 10)
      assert.is_false(result)
      assert.is_false(ws._ready)
    end)
  end)
end)

describe("ws_client POST body over stdin, real curl", function()
  it("a body of several MB arrives whole, with no temp file made", function()
    if vim.fn.executable("curl") ~= 1 then
      return pending("curl is not installed")
    end
    local uv = vim.uv
    local size = 6 * 1024 * 1024
    local body = string.rep("0123456789abcdef", size / 16)
    local got = { bytes = 0 }

    -- A relay stand-in that only counts what a POST carries.
    local server = uv.new_tcp()
    server:bind("127.0.0.1", 0)
    server:listen(8, function()
      local client = uv.new_tcp()
      server:accept(client)
      local head, length, seen, answered = "", nil, 0, false
      client:read_start(function(err, chunk)
        if err or not chunk then
          return
        end
        if not length then
          head = head .. chunk
          local at = head:find("\r\n\r\n", 1, true)
          if not at then
            return
          end
          length = tonumber(head:match("[Cc]ontent%-[Ll]ength: (%d+)"))
          chunk = head:sub(at + 4)
          if head:lower():find("expect: 100-continue", 1, true) then
            client:write("HTTP/1.1 100 Continue\r\n\r\n")
          end
        end
        seen = seen + #chunk
        if not answered and length and seen >= length then
          answered = true
          got.bytes, got.length = seen, length
          client:write("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n", function()
            client:close()
          end)
        end
      end)
    end)
    local port = server:getsockname().port

    local before = #vim.fn.glob(vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/*", false, true)
    local saved_port = vim.g.mdview_server_port
    vim.g.mdview_server_port = port
    local result
    ws.send_spotlight(body, function(ok, err)
      result = { ok, err }
    end)
    local done = vim.wait(20000, function()
      return result ~= nil
    end, 20)
    vim.g.mdview_server_port = saved_port
    local after = #vim.fn.glob(vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/*", false, true)
    server:close()

    assert.is_true(done, "no answer from curl")
    assert.is_true(result[1], tostring(result[2]))
    assert.are.equal(size, got.length)
    assert.are.equal(size, got.bytes)
    assert.is_true(after <= before + 1, "no new temp file per POST")
  end)
end)
