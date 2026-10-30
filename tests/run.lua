vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false

local tools = require("selection_tools")
local passed, failed = 0, 0
local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = message
end

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), ("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
end

local function drain()
  vim.wait(20, function()
    return false
  end, 1)
end

local function test(name, fn)
  local windows = vim.api.nvim_list_wins()
  local ok, err = xpcall(fn, debug.traceback)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not vim.list_contains(windows, win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  drain()
  tools.setup()
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end

test("filter returns the original object and original index", function()
  local first, second = { name = "alpha" }, { name = "beta", action = function() end }
  local calls = 0
  local origin = vim.api.nvim_get_current_win()
  local p = tools.select({ first, second }, {
    format_item = function(item)
      return item.name
    end,
  }, function(item, index)
    calls = calls + 1
    assert(item == second, "object identity changed")
    eq(index, 2)
    eq(vim.api.nvim_get_current_win(), origin)
  end)
  p:set_query("bta")
  eq(#p.matches, 1)
  eq(p:current(), second)
  p:confirm()
  p:close()
  eq(calls, 1)
  assert(not vim.api.nvim_buf_is_valid(p.input_buf))
  assert(not vim.api.nvim_buf_is_valid(p.list_buf))
end)

test("cancel and false-valued items have distinct indices", function()
  local calls = {}
  local p = tools.select({ false, true }, {}, function(item, index)
    calls[#calls + 1] = { item, index }
  end)
  p:confirm()
  eq(calls[1], { false, 1 })
  p = tools.select({}, {}, function(item, index)
    eq(item, nil)
    eq(index, nil)
    calls[#calls + 1] = "cancelled"
  end)
  p:confirm()
  assert(not p.closed, "empty confirmation should be a no-op")
  p:close()
  eq(calls[2], "cancelled")
end)

test("Unicode, fuzzy positions, wrapping and empty results", function()
  local p = tools.select({ "其他", "你好 world", "hello", "help" }, {}, function() end)
  p:set_query("你好")
  eq(p:current(), "你好 world")
  local marks = vim.api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })
  assert(#marks >= 3)
  p:set_query("hl")
  eq(#p.matches, 2)
  p:move(-1)
  eq(p.index, 2)
  p:move(1)
  eq(p.index, 1)
  p:set_query("zzz")
  eq(p:current(), nil)
  eq(vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false), { "No results" })
  p:close()
end)

test("buffer changes update filtering and normalize pasted newlines", function()
  local p = tools.select({ "alpha", "beta", "alpha beta" }, {}, function() end)
  vim.api.nvim_buf_set_lines(p.input_buf, 0, -1, false, { "beta" })
  drain()
  eq(p.query, "beta")
  eq(#p.matches, 2)
  vim.api.nvim_buf_set_lines(p.input_buf, 0, -1, false, { "alpha", "beta" })
  drain()
  eq(p.query, "alpha beta")
  eq(vim.api.nvim_buf_line_count(p.input_buf), 1)
  p:close()
end)

test("async sources discard stale generations and cancel work", function()
  local contexts, cancelled = {}, 0
  local p = tools.open({
    live = true,
    finder = function(ctx)
      contexts[#contexts + 1] = ctx
      return function()
        cancelled = cancelled + 1
      end
    end,
  })
  assert(p.loading)
  p:set_query("new")
  eq(cancelled, 1)
  assert(contexts[1].is_cancelled())
  contexts[2].set_items({ "new result" })
  contexts[2].done()
  contexts[1].set_items({ "stale" })
  contexts[1].done()
  drain()
  eq(p:current(), "new result")
  assert(not p.loading)
  p:close()
  eq(cancelled, 2)
  contexts[2].set_items({ "late" })
  contexts[2].done()
  drain()
end)

test("static async source scans once and filters cached items", function()
  local scans = 0
  local p = tools.open({
    finder = function(ctx)
      scans = scans + 1
      ctx.set_items({ "alpha", "beta" })
      ctx.done()
    end,
  })
  drain()
  p:set_query("beta")
  eq(scans, 1)
  eq(p:current(), "beta")
  p:close()
end)

test("finder errors are visible and picker stays cancellable", function()
  local p = tools.open({
    finder = function()
      error("fixture failure")
    end,
  })
  drain()
  assert(p.error:find("fixture failure", 1, true))
  assert(not p.loading)
  assert(vim.api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1]:find("Error:", 1, true))
  p:close()
end)

test("replacement, external window close and input wipe clean up once", function()
  local cancelled = 0
  local p = tools.select({ "old" }, {}, function()
    cancelled = cancelled + 1
  end)
  local next_picker = tools.select({ "new" }, {}, function()
    cancelled = cancelled + 1
  end)
  assert(p.closed)
  eq(cancelled, 1)
  vim.api.nvim_win_close(next_picker.list_win, true)
  drain()
  assert(next_picker.closed)
  eq(cancelled, 2)
  p = tools.select({ "wipe" }, {}, function()
    cancelled = cancelled + 1
  end)
  vim.api.nvim_buf_delete(p.input_buf, { force = true })
  drain()
  assert(p.closed)
  eq(cancelled, 3)
end)

test("registry, command and opt-in ui.select adapter", function()
  local original = vim.ui.select
  tools.setup({ ui_select = true })
  local adapter = vim.ui.select
  tools.setup({ ui_select = true })
  eq(vim.ui.select, adapter)
  local selected
  local p = vim.ui.select({ "choice" }, {}, function(item)
    selected = item
  end)
  p:confirm()
  eq(selected, "choice")
  tools.setup({ ui_select = false })
  eq(vim.ui.select, original)
  tools.register_source("fixture", { items = { "registered" } })
  p = tools.pick("fixture", { query = "reg" })
  eq(p:current(), "registered")
  p:close()
  tools.register_source("factory", function(opts)
    return { items = { opts.value } }
  end)
  p = tools.pick("factory", { value = "factory result" })
  eq(p:current(), "factory result")
  p:close()
  vim.cmd.runtime("plugin/selection_tools.lua")
  eq(vim.fn.getcompletion("SelectionTools fix", "cmdline"), { "fixture" })
  vim.cmd("SelectionTools fixture")
  vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
  drain()
  local other = function() end
  tools.setup({ ui_select = true })
  vim.ui.select = other
  tools.setup({ ui_select = false })
  eq(vim.ui.select, other)
  vim.ui.select = original
end)

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/sub", "p")
vim.fn.mkdir(fixture .. "/.git", "p")
vim.fn.writefile({}, fixture .. "/.git/config")
vim.fn.writefile({ "ignored.txt" }, fixture .. "/.gitignore")
for _, name in ipairs({ "normal.txt", "a space | % #.txt", "line\nbreak.txt", "ignored.txt", ".hidden", "sub/deep.lua" }) do
  vim.fn.writefile({ name }, fixture .. "/" .. name)
end

test("files respect cwd, ignore rules and exact unusual paths with fd and rg", function()
  local executable = vim.fn.executable
  for _, backend in ipairs({ "fd", "rg" }) do
    vim.fn.executable = function(name)
      if name == "fd" and backend == "rg" then
        return 0
      end
      return executable(name)
    end
    local ok, err = pcall(function()
      local p = tools.files({ cwd = fixture })
      assert(
        vim.wait(5000, function()
          return not p.loading
        end, 5),
        "file search timed out"
      )
      assert(not p.error, p.error)
      local names = vim.tbl_map(function(entry)
        return entry.item.text
      end, p.entries)
      assert(vim.list_contains(names, "normal.txt"))
      assert(vim.list_contains(names, "sub/deep.lua"))
      assert(not vim.list_contains(names, "ignored.txt"))
      assert(not vim.list_contains(names, ".hidden"))
      p:set_query("space")
      p:confirm()
      eq(vim.api.nvim_buf_get_name(0), vim.uv.fs_realpath(fixture .. "/a space | % #.txt"))
      p = tools.files({ cwd = fixture, hidden = true, ignored = true })
      assert(vim.wait(5000, function()
        return not p.loading
      end, 5))
      names = vim.tbl_map(function(entry)
        return entry.item.text
      end, p.entries)
      assert(vim.list_contains(names, "ignored.txt"))
      assert(vim.list_contains(names, ".hidden"))
      assert(not vim.list_contains(names, ".git/config"))
      p:set_query("line")
      eq(p:current().text, "line\nbreak.txt")
      p:confirm()
      eq(vim.api.nvim_buf_get_name(0), vim.uv.fs_realpath(fixture .. "/line\nbreak.txt"))
    end)
    vim.fn.executable = executable
    assert(ok, err)
  end
end)

test("missing file backend reports an actionable error", function()
  local executable = vim.fn.executable
  vim.fn.executable = function()
    return 0
  end
  local ok, p = pcall(tools.files, { cwd = fixture })
  vim.fn.executable = executable
  assert(ok, p)
  drain()
  assert(p.error:find("requires fd or ripgrep", 1, true))
  p:close()
end)

test("buffers switch to selected buffer and support excluding current", function()
  local original = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, fixture .. "/buffer-target")
  local p = tools.buffers({ current = false })
  for _, entry in ipairs(p.entries) do
    assert(entry.item.bufnr ~= original)
  end
  p:set_query("buffer-target")
  p:confirm()
  eq(vim.api.nvim_get_current_buf(), buf)
end)

test("invalid formatter fails without leaking windows", function()
  local windows = vim.api.nvim_list_wins()
  assert(not pcall(tools.select, { 1 }, {
    format_item = function()
      error("bad formatter")
    end,
  }, function() end))
  eq(vim.api.nvim_list_wins(), windows)
end)

test("invalid border and key configuration do not leak buffers or windows", function()
  local windows = vim.api.nvim_list_wins()
  local buffers = vim.api.nvim_list_bufs()
  local calls = 0
  for _, opts in ipairs({ { layout = { border = "invalid" } }, { keys = { invalid = { "x" } } } }) do
    assert(not pcall(tools.select, { "item" }, opts, function()
      calls = calls + 1
    end))
    drain()
    eq(vim.api.nvim_list_wins(), windows)
    eq(vim.api.nvim_list_bufs(), buffers)
  end
  eq(calls, 0)
end)

vim.fn.delete(fixture, "rf")
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
