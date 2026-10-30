vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local passed, failed = 0, 0
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function test(name, fn)
  local windows = vim.api.nvim_list_wins()
  local ok, err = xpcall(fn, debug.traceback)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not vim.tbl_contains(windows, win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  tools.setup()
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end
local function ready(p)
  assert(
    vim.wait(5000, function()
      return not p.loading and not p.matching
    end, 1),
    "source timed out"
  )
  assert(not p.error, p.error)
end
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")

test("highlight attributes are read only for the previewed item and reflect current colors", function()
  local get_hl, calls = vim.api.nvim_get_hl, {}
  vim.api.nvim_set_hl(0, "SelectionLazyHighlight", { fg = "#123456" })
  vim.api.nvim_get_hl = function(ns, opts)
    calls[#calls + 1] = opts.name
    return get_hl(ns, opts)
  end
  local ok, err = xpcall(function()
    local spec = require("selection_tools.sources.highlights")({})
    eq(#calls, 0)
    vim.api.nvim_set_hl(0, "SelectionLazyHighlight", { fg = "#654321" })
    local p = tools.open(vim.tbl_extend("force", spec, { query = "SelectionLazyHighlight" }))
    ready(p)
    assert(vim.wait(1000, function()
      return table
        .concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
        :find(tostring(0x654321), 1, true)
    end, 1))
    eq(calls, { "SelectionLazyHighlight", "SelectionLazyHighlight" })
    p:close()
  end, debug.traceback)
  vim.api.nvim_get_hl = get_hl
  assert(ok, err)
end)

test("keymap definitions are resolved only for preview or explicit definition navigation", function()
  local util = require("selection_tools.sources.util")
  local original, calls = util.definition, 0
  util.definition = function(...)
    calls = calls + 1
    return original(...)
  end
  vim.keymap.set("n", "<F7>", "<Nop>", { desc = "selection_lazy_mapping" })
  local buf = vim.api.nvim_get_current_buf()
  local ok, err = xpcall(function()
    local p = tools.keymaps({ modes = { "n" }, query = "selection_lazy_mapping", preview = { enabled = false } })
    ready(p)
    eq(calls, 0)
    p:confirm()
    vim.api.nvim_feedkeys("", "x", false)
    eq(calls, 0)
    p = tools.keymaps({
      modes = { "n" },
      query = "selection_lazy_mapping",
      preview = { enabled = false },
      action = "definition",
    })
    ready(p)
    eq(calls, 0)
    p:confirm()
    eq(calls, 1)
  end, debug.traceback)
  util.definition = original
  vim.keymap.del("n", "<F7>")
  vim.api.nvim_set_current_buf(buf)
  assert(ok, err)
end)

test("script indexes are reused within a picker and refreshed for a new picker", function()
  local getscriptinfo, calls = vim.fn.getscriptinfo, 0
  vim.fn.getscriptinfo = function()
    calls = calls + 1
    return { { sid = 100, name = fixture .. "/first.vim" }, { sid = 200, name = fixture .. "/second.vim" } }
  end
  local ok, err = xpcall(function()
    local definitions = require("selection_tools.sources.util").definitions
    local resolve = definitions()
    eq(calls, 0)
    eq(resolve(nil, 100, 3).pos, { 3, 0 })
    eq(resolve(nil, 200, 7).file, fixture .. "/second.vim")
    eq(calls, 1)
    eq(definitions()(nil, 100, 1).file, fixture .. "/first.vim")
    eq(calls, 2)
  end, debug.traceback)
  vim.fn.getscriptinfo = getscriptinfo
  assert(ok, err)
end)

vim.fn.delete(fixture, "rf")
print(("%d lazy-loading tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
