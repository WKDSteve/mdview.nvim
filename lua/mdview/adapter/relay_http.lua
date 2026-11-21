---@module 'mdview.adapter.relay_http'
-- A short request to the relay over a plain TCP connection, without curl.
--
-- For the few requests that must finish before the caller goes on -- the close
-- signal and the detach right before the relay or Neovim goes away, the probe
-- of a shared relay on `:MDView start`. With curl each of them cost a process
-- start on the editor thread: on Windows 150-450 ms under load, even when the
-- relay answers in 2 ms. A loopback connection costs a few milliseconds.
--
-- HTTP/1.0 with `Connection: close`: the relay (Go net/http) answers and closes,
-- so the answer is everything read until EOF. Only what these callers need:
-- no redirects, no chunked bodies (the relay sends none for these routes).

local relay_url = require("mdview.adapter.relay_url")

local M = {}

--- Send `method target` to the relay on `port` and wait up to `timeout_ms` for
--- the whole answer. The body of any HTTP answer (as `curl -sS` printed it, any
--- status); nil and a reason when nothing answered in time.
---
--- Waits with vim.wait, so it must not run in a fast callback (`vim.in_fast_event()`).
---@param port integer
---@param method "GET"|"POST"
---@param target string # path and query, e.g. "/close?token=..."
---@param timeout_ms integer
---@return string|nil body, string|nil err
function M.request_sync(port, method, target, timeout_ms)
  local uv = vim.uv or vim.loop
  local tcp = uv.new_tcp()
  if not tcp then
    return nil, "no TCP handle"
  end
  local chunks = {}
  local done, err = false, nil

  ---@param e string|nil
  local function finish(e)
    if done then
      return
    end
    done, err = true, e
    if not tcp:is_closing() then
      tcp:close()
    end
  end

  local request = ("%s %s HTTP/1.0\r\nHost: %s:%d\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"):format(
    method,
    target,
    relay_url.HOST,
    port
  )
  local ok, rc, cerr = pcall(tcp.connect, tcp, relay_url.HOST, port, function(connect_err)
    if connect_err then
      finish(connect_err)
      return
    end
    tcp:read_start(function(read_err, data)
      if read_err then
        finish(read_err)
      elseif data then
        chunks[#chunks + 1] = data
      else
        finish(nil)
      end
    end)
    tcp:write(request)
  end)
  if not ok or not rc then
    finish(tostring(ok and cerr or rc))
  end

  vim.wait(timeout_ms, function()
    return done
  end, 5)
  if not done then
    finish("timeout after " .. timeout_ms .. " ms")
  end
  if err then
    return nil, err
  end

  local answer = table.concat(chunks)
  local head, body = answer:match("^(.-)\r\n\r\n(.*)$")
  if not head or not head:match("^HTTP/1%.%d %d%d%d") then
    return nil, "no HTTP answer"
  end
  return body, nil
end

return M
