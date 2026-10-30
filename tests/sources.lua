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
vim.fn.mkdir(fixture .. "/sub", "p")

test("live grep handles literal text, unusual paths, preview positions and stale queries", function()
  local path = fixture .. "/sub/a | b.txt"
  vim.fn.writefile({ "nothing", "prefix needle[1] suffix", "final" }, path)
  local p = tools.grep({ cwd = fixture, debounce_ms = 0 })
  ready(p)
  eq(#p.entries, 0)
  p:set_query("nothing")
  p:set_query("needle[1]")
  ready(p)
  eq(#p.entries, 1)
  eq(p:current().pos, { 2, 7 })
  eq(p:current().file, path)
  p:confirm()
  eq(vim.api.nvim_buf_get_name(0), vim.uv.fs_realpath(path))
  eq(vim.api.nvim_win_get_cursor(0), { 2, 7 })
  p = tools.grep({ cwd = fixture, query = "^prefix", regex = true, debounce_ms = 0 })
  ready(p)
  eq(#p.entries, 1)
  p:close()
end)

test("projects combine explicit, recent and discovered roots without duplicates", function()
  local cwd, oldfiles = vim.fn.getcwd(), vim.v.oldfiles
  vim.fn.mkdir(fixture .. "/work/one/.git", "p")
  vim.fn.mkdir(fixture .. "/work/two/.git", "p")
  vim.fn.writefile({ "one" }, fixture .. "/work/one/file.txt")
  vim.v.oldfiles = { fixture .. "/work/one/file.txt" }
  local ok, err = pcall(function()
    local p =
      tools.projects({ projects = { fixture .. "/work/one" }, dev = { fixture .. "/work" }, open_files = false })
    local count = 0
    for _, entry in ipairs(p.entries) do
      if entry.item.dir == vim.uv.fs_realpath(fixture .. "/work/one") then
        count = count + 1
      end
    end
    eq(count, 1)
    p:set_query("work/two")
    eq(#p.matches, 1)
    p:confirm()
    eq(vim.fn.getcwd(), vim.uv.fs_realpath(fixture .. "/work/two"))
  end)
  vim.api.nvim_set_current_dir(cwd)
  vim.v.oldfiles = oldfiles
  assert(ok, err)
end)

vim.fn.delete(fixture, "rf")
print(("%d source tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
