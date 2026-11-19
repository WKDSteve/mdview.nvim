-- @cache-inputs TESTS/sheets/
---@module 'tests.nvim.sheet_relay_setup_spec'
-- The setup of the relay feature sheets (TESTS/sheets/_relay.lua) picks the relay's port. `:MDView standalone`
-- listens on `server_port + 100`, so a port from the system's ephemeral range (port 0; on Windows up to 65535) could
-- leave it no valid port: the setup picks one between 20000 and 39999 that nobody listens on.

---@diagnostic disable: undefined-global

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

describe("TESTS/sheets/_relay.lua", function()
  local globals

  before_each(function()
    globals = {}
    for k in pairs(_G) do
      globals[k] = true
    end
  end)

  after_each(function()
    -- Loading the file defines the helpers of the sheets on _G; take them away again.
    for k in pairs(_G) do
      if not globals[k] then
        _G[k] = nil
      end
    end
  end)

  it("picks a free port between 20000 and 39999, so standalone's port + 100 is a port too", function()
    local relay = dofile(root .. "/TESTS/sheets/_relay.lua")
    for _ = 1, 200 do
      local port = relay.free_port()
      assert(port >= 20000 and port <= 39999, "port out of range: " .. tostring(port))
      local tcp = assert(vim.uv.new_tcp())
      local ok = tcp:bind("127.0.0.1", port)
      tcp:close()
      assert(ok, "port " .. port .. " is taken")
    end
  end)

  it("loads without changing the editor: vim.notify stays", function()
    local notify = vim.notify
    dofile(root .. "/TESTS/sheets/_relay.lua")
    assert(vim.notify == notify, "loading _relay.lua replaced vim.notify")
  end)
end)
