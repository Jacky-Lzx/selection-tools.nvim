vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local passed, failed = 0, 0
vim.notify = function() end
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
  vim.wait(10, function()
    return false
  end, 1)
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
    end, 2),
    "source timed out"
  )
  assert(not p.error, p.error)
end
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
fixture = vim.uv.fs_realpath(fixture)
local function picker()
  return tools.open({
    items = {
      { file = fixture .. "/a |%.lua", pos = { 3, 2 }, code = "needle first", text = "needle a" },
      { file = fixture .. "/b.lua", pos = { 4, 5 }, code = "needle second", text = "needle b" },
      { file = fixture .. "/c.lua", text = "other" },
    },
    multi = true,
    query = "needle",
    format_item = function(item)
      return item.text
    end,
  })
end
test("quickfix exports all filtered results or explicit marks with exact locations", function()
  local p = picker()
  require("selection_tools.actions").export(p, false)
  assert(p.closed)
  local qf = vim.fn.getqflist()
  eq(#qf, 2)
  eq(qf[1].lnum, 3)
  eq(qf[1].col, 3)
  eq(vim.api.nvim_buf_get_name(qf[1].bufnr), fixture .. "/a |%.lua")
  eq(qf[2].text, "needle second")
  vim.cmd.cclose()
  p = picker()
  p:toggle()
  require("selection_tools.actions").export(p, false)
  eq(#vim.fn.getqflist(), 1)
  vim.cmd.cclose()
  p = picker()
  p:toggle()
  require("selection_tools.actions").export(p, false, true)
  eq(#vim.fn.getqflist(), 2)
  vim.cmd.cclose()
end)
test("location exports target the calling window and empty exports keep picker open", function()
  local origin = vim.api.nvim_get_current_win()
  local p = picker()
  require("selection_tools.actions").export(p, true)
  eq(#vim.fn.getloclist(origin), 2)
  vim.cmd.lclose()
  p = tools.open({ items = { "no file location" } })
  require("selection_tools.actions").export(p, true)
  assert(not p.closed)
  p:close()
end)
vim.fn.delete(fixture, "rf")
print(("%d workflow tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
