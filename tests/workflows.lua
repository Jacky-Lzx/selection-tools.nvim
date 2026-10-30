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
test("search options restart the same query, filter globs, change scope and survive resume", function()
  local dir = fixture .. "/options"
  vim.fn.mkdir(dir .. "/sub", "p")
  vim.fn.writefile({ "needle Needle needle[1]" }, dir .. "/a.lua")
  vim.fn.writefile({ "needle" }, dir .. "/b.rs")
  vim.fn.writefile({ "needle" }, dir .. "/sub/c.lua")
  local p = tools.grep({ cwd = dir, query = "needle[1]", debounce_ms = 0 })
  ready(p)
  eq(#p.matches, 1)
  p:set_search_options({ regex = true })
  ready(p)
  eq(#p.matches, 0)
  p:set_query("Needle")
  p:set_search_options({ case = "sensitive" })
  ready(p)
  eq(#p.matches, 1)
  p:set_search_options({ case = "ignore", globs = { "*.lua", "!sub/**" } })
  ready(p)
  eq(#p.matches, 1)
  p:set_search_options({ cwd = "sub", globs = {} })
  ready(p)
  eq(#p.matches, 1)
  eq(vim.fs.basename(p:current().file), "c.lua")
  assert(not pcall(p.set_search_options, p, { case = "invalid" }))
  assert(not pcall(p.set_search_options, p, { cwd = "does-not-exist" }))
  eq(p.query, "Needle")
  p:close()
  p = tools.resume()
  ready(p)
  eq(p.opts.case, "ignore")
  eq(p.opts.cwd, dir .. "/sub")
  eq(#p.matches, 1)
  p:close()
  p = tools.files({ cwd = dir })
  ready(p)
  p:set_search_options({ globs = { "*.rs" } })
  ready(p)
  eq(#p.matches, 1)
  eq(vim.fs.basename(p:current().file), "b.rs")
  p:close()
end)
test("hidden and ignored files are independently controlled", function()
  local dir = fixture .. "/flags"
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "skip.lua" }, dir .. "/.ignore")
  vim.fn.writefile({ "needle" }, dir .. "/.hidden.lua")
  vim.fn.writefile({ "needle" }, dir .. "/skip.lua")
  local p = tools.grep({ cwd = dir, query = "needle", debounce_ms = 0 })
  ready(p)
  eq(#p.matches, 0)
  p:set_search_options({ hidden = true })
  ready(p)
  eq(#p.matches, 1)
  p:set_search_options({ ignored = true })
  ready(p)
  eq(#p.matches, 2)
  p:close()
end)
test("split, vertical split and tabs preserve dirty buffers and exact positions", function()
  local file = fixture .. "/split | %.lua"
  vim.fn.writefile({ "one", "two", "three", "four" }, file)
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "dirty three" })
  local origin = vim.api.nvim_get_current_win()
  for _, mode in ipairs({ "split", "vsplit", "tab" }) do
    local p = tools.open({
      items = { { file = file, pos = { 3, 2 } } },
      format_item = function(item)
        return item.file
      end,
    })
    require("selection_tools.actions").edit(p, mode)
    assert(p.closed and vim.api.nvim_get_current_win() ~= origin)
    eq(vim.api.nvim_get_current_buf(), buf)
    eq(vim.api.nvim_win_get_cursor(0), { 3, 2 })
    eq(vim.api.nvim_buf_get_lines(buf, 2, 3, false), { "dirty three" })
    assert(vim.bo[buf].modified)
    vim.cmd(mode == "tab" and "tabclose" or "close")
    vim.api.nvim_set_current_win(origin)
  end
  vim.bo[buf].modified = false
end)
test("multi-selection opens one window per selected location", function()
  local count = #vim.api.nvim_list_wins()
  local p = picker()
  p:toggle()
  p:move(1)
  p:toggle()
  require("selection_tools.actions").edit(p, "vsplit")
  eq(#vim.api.nvim_list_wins(), count + 2)
  eq(vim.fs.basename(vim.api.nvim_buf_get_name(0)), "b.lua")
end)
vim.fn.delete(fixture, "rf")
print(("%d workflow tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
