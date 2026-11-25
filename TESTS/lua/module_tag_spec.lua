---@module 'tests.lua.module_tag_spec'
-- The `---@module` tag of `lua/mdview/init.lua` is the name `require` uses for it. A tag of `mdview.init` made
-- docmap read every `require("mdview")` of the tree as a module nobody declares (`require-not-declared`).

---@diagnostic disable: undefined-global

local assert = require("luassert")

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

describe("module tag of the entry point", function()
  it("declares the module as it is required", function()
    local first = vim.fn.readfile(root .. "/lua/mdview/init.lua", "", 1)[1]
    assert.are.equal("---@module 'mdview'", first)
  end)
end)
