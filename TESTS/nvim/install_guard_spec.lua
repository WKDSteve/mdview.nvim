---@module 'tests.nvim.install_guard_spec'
-- vim.g.lib_binaries ("manual" | "never") stops mdview from downloading its server and client bundle
-- unasked (lib.nvim.binaries). The guard sits before any network or disk access, so nothing is touched.

---@diagnostic disable: undefined-global

local install = require("mdview.adapter.install")
local config = require("mdview.config")
local binaries = require("lib.nvim.binaries")

local orig_version = config.defaults.install.version
local saved = vim.g.lib_binaries
config.defaults.install.version = "v0.0.0-mdview-guard-spec-" .. tostring(vim.uv.hrtime())
teardown(function()
  config.defaults.install.version = orig_version
  vim.g.lib_binaries = saved
end)

describe("install guard (vim.g.lib_binaries)", function()
  after_each(function()
    vim.g.lib_binaries = saved
  end)

  it("registers itself for fetching on request", function()
    assert.is_true(vim.tbl_contains(binaries.registered(), "mdview.nvim"))
    assert.is_truthy(binaries.status()["mdview.nvim"]:find("server missing", 1, true))
  end)

  it("downloads nothing unasked in manual and says how to get it", function()
    vim.g.lib_binaries = "manual"
    local path, err = install.ensure_binary()
    assert.is_nil(path)
    assert.is_truthy(err:find("on request only", 1, true))
    local web_root, web_err = install.ensure_client_bundle()
    assert.is_nil(web_root)
    assert.is_truthy(web_err:find("on request only", 1, true))
    assert.is_false(install.status().binary_installed)
  end)

  it("downloads nothing in never, not even on request", function()
    vim.g.lib_binaries = "never"
    local _, err = install.ensure_binary()
    assert.is_truthy(err:find("off", 1, true))
    local res = binaries.fetch("mdview.nvim")
    assert.is_false(res["mdview.nvim"].ok)
  end)
end)
