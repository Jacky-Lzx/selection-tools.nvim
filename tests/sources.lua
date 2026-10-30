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

test("recent files retain MRU order, skip deleted files and deduplicate aliases", function()
  local oldfiles = vim.v.oldfiles
  vim.fn.writefile({ "recent" }, fixture .. "/recent.txt")
  vim.v.oldfiles = { fixture .. "/recent.txt", fixture .. "/missing.txt", fixture .. "/sub/../recent.txt" }
  local ok, err = pcall(function()
    local p = tools.recent({ buffers = false, cwd = fixture })
    eq(#p.entries, 1)
    eq(p:current().file, vim.uv.fs_realpath(fixture .. "/recent.txt"))
    p:confirm()
    eq(vim.api.nvim_buf_get_name(0), vim.uv.fs_realpath(fixture .. "/recent.txt"))
  end)
  vim.v.oldfiles = oldfiles
  assert(ok, err)
end)

test("resume restores source objects, query, marks, cursor and preview scroll", function()
  local a, b = { text = "alpha" }, { text = "beta" }
  local lines = {}
  for i = 1, 100 do
    lines[i] = "line " .. i
  end
  local p = tools.open({
    items = { a, b },
    multi = true,
    query = "a",
    preview = { enabled = true },
    format_item = function(item)
      return item.text
    end,
    previewer = function(ctx)
      ctx.set_lines(lines)
    end,
  })
  p:move(1)
  local current = p:current()
  p:toggle()
  assert(vim.wait(1000, function()
    return vim.api.nvim_buf_line_count(p.preview_buf) == 100
  end, 2))
  p:scroll_preview(1)
  local row = vim.api.nvim_win_get_cursor(p.preview_win)[1]
  p:close()
  p = tools.resume()
  ready(p)
  eq(p.query, "a")
  assert(p:current() == current and p:selected()[1] == current)
  assert(vim.wait(1000, function()
    return vim.api.nvim_win_get_cursor(p.preview_win)[1] == row
  end, 2))
  p:close()
  p = tools.grep({ cwd = fixture, query = "needle", debounce_ms = 0 })
  ready(p)
  local item = p:current()
  p:toggle()
  p:close()
  p = tools.resume()
  ready(p)
  eq(p.query, "needle")
  eq(p:current().file, item.file)
  eq(#p:selected(), 1)
  p:close()
end)

test("TODO source includes NOTE by default and supports exact keyword filters", function()
  vim.fn.mkdir(fixture .. "/todo", "p")
  vim.fn.writefile(
    { "-- TODO: first", "-- NOTE: information", "-- FIXME: repair", "TODO without colon" },
    fixture .. "/todo/sample.lua"
  )
  local p = tools.todo_comments({ cwd = fixture .. "/todo", debounce_ms = 0 })
  ready(p)
  eq(#p.entries, 3)
  p:close()
  p = tools.todo_comments({ cwd = fixture .. "/todo", keywords = { "TODO", "FIXME" }, debounce_ms = 0 })
  ready(p)
  eq(#p.entries, 2)
  p:set_query("FIXME")
  eq(p:current().keyword, "FIXME")
  p:confirm()
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
end)

test("register search previews multiline values and preserves register type when copying", function()
  local a, b = vim.fn.getreginfo("a"), vim.fn.getreginfo("b")
  vim.fn.setreg("a", { "first", "second" }, "V")
  local ok, err = pcall(function()
    local p = tools.registers({ registers = "a", register = "b" })
    eq(#p.entries, 1)
    eq(p:current().lines, { "first", "second" })
    p:confirm()
    eq(vim.fn.getreg("b", 1, true), { "first", "second" })
    eq(vim.fn.getregtype("b"), "V")
  end)
  vim.fn.setreg("a", a)
  vim.fn.setreg("b", b)
  assert(ok, err)
end)

test("jump source navigates the native window jump list", function()
  vim.cmd.enew()
  local lines = {}
  for i = 1, 30 do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.cmd("clearjumps")
  vim.cmd("normal! 1G")
  vim.cmd("normal! 10G")
  vim.cmd("normal! 20G")
  local p = tools.jumps()
  assert(#p.entries > 0)
  local target
  for i, entry in ipairs(p.matches) do
    if entry.item.pos[1] == 10 then
      p.index = i
      target = entry.item
      break
    end
  end
  assert(target)
  p:confirm()
  eq(vim.api.nvim_win_get_cursor(0)[1], 10)
  vim.bo.modified = false
end)

test("mark source includes local and global marks and jumps to their exact columns", function()
  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first", "second line" })
  vim.api.nvim_buf_set_mark(0, "a", 2, 3, {})
  vim.api.nvim_buf_set_mark(0, "A", 1, 1, {})
  local p = tools.marks()
  local names = {}
  for i, entry in ipairs(p.matches) do
    names[entry.item.name] = true
    if entry.item.name == "'a" then
      p.index = i
    end
  end
  assert(names["'a"] and names["'A"])
  p:confirm()
  eq(vim.api.nvim_win_get_cursor(0), { 2, 3 })
  vim.api.nvim_buf_del_mark(0, "a")
  vim.api.nvim_del_mark("A")
  vim.bo.modified = false
end)

test("undo history previews a cloned tree and changes the original only on confirmation", function()
  vim.cmd.enew()
  vim.cmd("normal! ifirst\027")
  vim.cmd("normal! A\007u second\027")
  local original = vim.api.nvim_get_current_buf()
  local lines, tick = vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.api.nvim_buf_get_changedtick(0)
  local current_seq = vim.fn.undotree().seq_cur
  local p = tools.undo()
  local seq
  for i, entry in ipairs(p.matches) do
    if entry.item.seq > 0 and entry.item.seq < current_seq then
      p.index = i
      seq = entry.item.seq
      break
    end
  end
  assert(seq, "missing prior undo sequence")
  p:_render()
  assert(vim.wait(1000, function()
    return vim.bo[p.preview_buf].filetype == "diff"
  end, 2))
  eq(vim.api.nvim_buf_get_lines(original, 0, -1, false), lines)
  eq(vim.api.nvim_buf_get_changedtick(original), tick)
  p:confirm()
  eq(vim.api.nvim_buf_get_lines(original, 0, -1, false), { "first" })
  vim.bo.modified = false
end)

test("search history restores the search register and searches the original window", function()
  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "start", "history_target" })
  vim.fn.histadd("/", "history_target")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local p = tools.search_history({ query = "history_target" })
  p:confirm()
  eq(vim.fn.getreg("/"), "history_target")
  eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })
  vim.bo.modified = false
end)

test("command history runs the confirmed command in the original window", function()
  vim.fn.histadd(":", "let g:selection_history_test = 42")
  local p = tools.command_history({ query = "selection_history_test" })
  eq(#p.matches, 1)
  p:confirm()
  eq(vim.g.selection_history_test, 42)
  vim.g.selection_history_test = nil
end)

test("quickfix selection previews and updates the native list index", function()
  vim.fn.writefile({ "first", "second" }, fixture .. "/quickfix.txt")
  vim.fn.setqflist({}, " ", {
    title = "test",
    items = {
      { filename = fixture .. "/quickfix.txt", lnum = 1, col = 1, text = "one" },
      { filename = fixture .. "/quickfix.txt", lnum = 2, col = 2, text = "two" },
    },
  })
  local p = tools.qflist({ query = "two" })
  p:confirm()
  eq(vim.fn.getqflist({ idx = 0 }).idx, 2)
  eq(vim.api.nvim_win_get_cursor(0), { 2, 1 })
end)

test("location list belongs to the invoking window and rejects changed lists", function()
  local origin = vim.api.nvim_get_current_win()
  vim.fn.setloclist(
    origin,
    {},
    " ",
    { items = {
      { filename = fixture .. "/quickfix.txt", lnum = 1, col = 3, text = "location" },
    } }
  )
  local p = tools.loclist()
  eq(#p.entries, 1)
  p:confirm()
  eq(vim.api.nvim_get_current_win(), origin)
  eq(vim.api.nvim_win_get_cursor(0), { 1, 2 })
  p = tools.loclist()
  vim.fn.setloclist(origin, {}, "r", { items = {} })
  p:confirm()
  eq(vim.api.nvim_win_get_cursor(0), { 1, 2 })
end)

test("commands include builtins and prefer buffer-local definitions", function()
  vim.api.nvim_create_user_command("SelectionFeatureCommand", function()
    vim.g.selection_command_test = "global"
  end, {})
  vim.api.nvim_buf_create_user_command(0, "SelectionFeatureCommand", function()
    vim.g.selection_command_test = "buffer"
  end, {})
  local p = tools.commands({ query = "SelectionFeatureCommand", execute = true })
  eq(#p.matches, 1)
  assert(p:current().text:find("buffer", 1, true))
  p:confirm()
  eq(vim.g.selection_command_test, "buffer")
  p = tools.commands({ query = "edit" })
  assert(#p.matches > 0)
  p:close()
  vim.api.nvim_buf_del_user_command(0, "SelectionFeatureCommand")
  vim.api.nvim_del_user_command("SelectionFeatureCommand")
  vim.g.selection_command_test = nil
end)

test("autocommands show metadata without executing the event", function()
  local group = vim.api.nvim_create_augroup("SelectionSourceTest", { clear = true })
  local calls = 0
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "SelectionNoRun",
    desc = "selection_autocmd_test",
    callback = function()
      calls = calls + 1
    end,
  })
  local p = tools.autocmds({ query = "selection_autocmd_test" })
  eq(#p.matches, 1)
  assert(p:current().detail:find("SelectionNoRun", 1, true))
  p:close()
  eq(calls, 0)
  vim.api.nvim_del_augroup_by_id(group)
end)

vim.fn.delete(fixture, "rf")
print(("%d source tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
