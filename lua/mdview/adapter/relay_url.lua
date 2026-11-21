---@module 'mdview.adapter.relay_url'
-- The address every request of this plugin to its relay goes to.
--
-- The relay listens on 127.0.0.1 only (native/server/main.go). A URL that names
-- `localhost` makes curl try `::1` first, and on Windows a refused IPv6 connect
-- costs ~200 ms before curl falls back to 127.0.0.1: every curl to the relay
-- then took ~210 ms instead of ~2 ms, and the blocking ones (/close, /attach,
-- /detach) froze the editor that long. So the transport names the IPv4 loopback
-- address directly. The URL a browser tab opens stays `localhost`: that is the
-- page's origin (cookies, storage), and a browser resolves it differently.

local M = {}

--- The host of every request to the relay.
M.HOST = "127.0.0.1"

--- `http://127.0.0.1:<port>`, without a trailing slash.
---@param port integer
---@return string
function M.base(port)
  return ("http://%s:%d"):format(M.HOST, port)
end

return M
