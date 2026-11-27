---@module 'tests.lua.module_tag_spec'
-- Every `---@module '<name>'` tag under lua/ names the module its file is: the path below lua/ with dots, and the
-- directory for an init.lua. docmap reports a mismatch as an error (module-path-mismatch), and a wrong tag makes
-- LuaLS and the docs name a module that cannot be required.

---@diagnostic disable: undefined-global

local assert = require("luassert")

describe("@module tags", function()
  it("agree with the file path", function()
    local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))))
    local mismatched, checked = {}, 0
    for name, kind in vim.fs.dir(root .. "/lua", { depth = 20 }) do
      if kind == "file" and name:match("%.lua$") then
        local path = root .. "/lua/" .. name
        local line = vim.fn.readfile(path, "", 5)
        for _, l in ipairs(line) do
          local tag = l:match("^%-%-%-@module%s+['\"]([%w_.]+)['\"]")
          if tag then
            checked = checked + 1
            local want = name:gsub("%.lua$", ""):gsub("/", "."):gsub("%.init$", "")
            if tag ~= want then
              mismatched[#mismatched + 1] = name .. ": tag " .. tag .. ", module " .. want
            end
            break
          end
        end
      end
    end
    assert.is_true(checked > 20, "the scan must find the tags (found " .. checked .. ")")
    assert.are.same({}, mismatched)
  end)
end)
