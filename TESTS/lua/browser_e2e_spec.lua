---@module 'tests.lua.browser_e2e_spec'
-- Tier 3: the Playwright scripts of TESTS/browser, run as cases of the suite. A script that exits 77 has a
-- missing prerequisite (relay binary, client bundle, chromium): the case is a reported skip, never a green run.

---@diagnostic disable: undefined-global

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local SKIP = 77

---@param script string
---@return integer code, string output
local function run(script)
  local done = vim.system({ "node", root .. "/TESTS/browser/" .. script }, { cwd = root, text = true }):wait(120000)
  return done.code, (done.stdout or "") .. (done.stderr or "")
end

describe("browser e2e (tier 3)", function()
  it("@spawn @network the cursor-line band sits on the cursor line and follows it", function()
    if vim.fn.executable("node") ~= 1 then
      print("n/a  node is not installed")
      return
    end
    local code, out = run("cursor_band.e2e.mjs")
    if code == SKIP then
      print("n/a  " .. out:gsub("%s+$", ""))
      return
    end
    assert(code == 0, out)
  end)
end)
