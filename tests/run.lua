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

test("counts share the input row and dividers join the frame without preview titles", function()
  for _, position in ipairs({ "top", "bottom" }) do
    local p = tools.open({
      items = { "alpha", "beta" },
      multi = true,
      preview = { enabled = true },
      previewer = function(ctx)
        ctx.set_lines({ "first", "second" }, nil, "hidden-filename.lua")
      end,
      layout = { height = 0.9, input_position = position },
    })
    drain()
    local function count()
      local marks = vim.api.nvim_buf_get_extmarks(p.frame_buf, -1, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        if mark[4].virt_text then
          eq(mark[2], position == "top" and 0 or p.resolved.total_height - 1)
          eq(mark[4].virt_text_pos, "right_align")
          return mark[4].virt_text[1][1]
        end
      end
      error("missing input count")
    end
    eq(count(), " 2/2 ")
    eq(vim.api.nvim_win_get_config(p.frame_win).footer, nil)
    eq(vim.api.nvim_win_get_width(p.input_win) + vim.fn.strdisplaywidth(count()), p.resolved.width)
    eq(
      vim.api.nvim_buf_get_lines(p.separator_buf, 0, -1, false),
      { "├" .. string.rep("─", p.resolved.width) .. "┤" }
    )
    for i, win in ipairs(p.separator_wins) do
      local config = vim.api.nvim_win_get_config(win)
      eq(config.row, p.resolved.frame.row + p.resolved.separators[i] + 1)
      eq(config.col, p.resolved.frame.col)
      eq(config.width, p.resolved.width + 2)
    end
    assert(vim.wo[p.preview_win].number and not vim.wo[p.preview_win].relativenumber)
    p:toggle()
    assert(count():find("1 selected", 1, true))
    p:set_query("beta")
    assert(count():find("1/2", 1, true))
    p:set_query(string.rep("long query ", 20))
    eq(count():sub(1, 5), " 0/2 ")
    assert(vim.api.nvim_win_get_width(p.input_win) > 0)
    local wins, buf = vim.deepcopy(p.separator_wins), p.separator_buf
    p:close()
    for _, win in ipairs(wins) do
      assert(not vim.api.nvim_win_is_valid(win))
    end
    assert(not vim.api.nvim_buf_is_valid(buf))
  end
end)

test("double borders use matching divider joints", function()
  local p = tools.open({ items = { "item" }, layout = { border = "double" } })
  eq(
    vim.api.nvim_buf_get_lines(p.separator_buf, 0, -1, false),
    { "╠" .. string.rep("═", p.resolved.width) .. "╣" }
  )
  p:close()
end)

test("vertical reversed layout keeps the best match next to the bottom input", function()
  local items = {}
  for i = 1, 80 do
    items[i] = ("item %02d"):format(i)
  end
  local p = tools.open({
    items = items,
    multi = true,
    preview = { enabled = true },
    layout = { width = 0.8, height = 0.9, min_width = 60, input_position = "bottom", reverse = true },
  })
  local preview = vim.api.nvim_win_get_position(p.preview_win)
  local list = vim.api.nvim_win_get_position(p.list_win)
  local input = vim.api.nvim_win_get_position(p.input_win)
  assert(preview[1] < list[1] and list[1] < input[1])
  eq(vim.api.nvim_win_get_cursor(p.list_win)[1], p.height)
  p:move_visual(-1)
  eq(p.index, 2)
  eq(vim.api.nvim_win_get_cursor(p.list_win)[1], p.height - 1)
  p:scroll_list(-1)
  assert(p.index > 2)
  p:scroll_list(1)
  eq(p.index, 2)
  vim.api.nvim_exec_autocmds("VimResized", {})
  assert(not p.closed)
  p:close()
  assert(not vim.api.nvim_win_is_valid(p.frame_win))
  assert(not vim.api.nvim_win_is_valid(p.preview_win))
  assert(not vim.api.nvim_buf_is_valid(p.preview_buf))
end)

test("multiselection survives filtering and preserves object identity", function()
  local a, b = { text = "alpha" }, { text = "beta" }
  local chosen
  local p = tools.open({
    items = { a, b },
    multi = true,
    format_item = function(item)
      return item.text
    end,
    on_choice = function(item, index, selected)
      chosen = { item, index, selected }
    end,
  })
  p:toggle()
  p:set_query("beta")
  p:toggle()
  local selected = p:selected()
  assert(selected[1] == a and selected[2] == b)
  p:confirm()
  assert(chosen[1] == b and chosen[2] == 2 and chosen[3][1] == a and chosen[3][2] == b)
end)

test("short-screen resizing hides and restores preview without losing the query", function()
  local lines = vim.o.lines
  local p = tools.open({ items = { "match" }, query = "mat", preview = { enabled = true }, layout = { height = 0.9 } })
  local ok, err = pcall(function()
    assert(p.preview_win)
    vim.o.lines = 9
    vim.api.nvim_exec_autocmds("VimResized", {})
    drain()
    assert(not p.closed and not p.preview_win)
    eq(p.query, "mat")
    vim.o.lines = lines
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(p.preview_win and not p.closed)
    assert(vim.wo[p.preview_win].number and not vim.wo[p.preview_win].relativenumber)
    eq(#p.separator_wins, 2)
    eq(vim.api.nvim_win_get_width(p.input_win) + 5, p.resolved.width)
    eq(p:current(), "match")
  end)
  vim.o.lines = lines
  p:close()
  assert(ok, err)
end)

test("file preview is asynchronous, highlighted and does not create a file buffer", function()
  local path = fixture .. "/preview.lua"
  vim.fn.writefile({ "local value = 1", "return value" }, path)
  local before = vim.api.nvim_get_current_buf()
  local p = tools.files({ cwd = fixture, query = "preview.lua" })
  assert(vim.wait(5000, function()
    return not p.loading and vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "local value = 1"
  end, 5))
  eq(vim.bo[p.preview_buf].filetype, "lua")
  eq(vim.fn.bufnr(path), -1)
  eq(vim.api.nvim_get_current_win(), p.input_win)
  p:close()
  eq(vim.api.nvim_get_current_buf(), before)
end)

test("buffer preview shows unsaved text without modifying the source buffer", function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, fixture .. "/dirty-buffer.lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved contents" })
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local p = tools.buffers({ query = "dirty-buffer" })
  eq(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), { "unsaved contents" })
  p:close()
  assert(vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified)
  eq(vim.api.nvim_buf_get_changedtick(buf), tick)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("preview scroll preserves input focus and file limits are visible", function()
  local lines = {}
  for i = 1, 100 do
    lines[i] = "line " .. i
  end
  vim.fn.writefile(lines, fixture .. "/scroll.txt")
  local p = tools.files({ cwd = fixture, query = "scroll.txt" })
  assert(vim.wait(5000, function()
    return vim.api.nvim_buf_line_count(p.preview_buf) == 100
  end, 5))
  p:scroll_preview(1)
  assert(vim.api.nvim_win_get_cursor(p.preview_win)[1] > 1)
  eq(vim.api.nvim_get_current_win(), p.input_win)
  p:scroll_preview(-1)
  p:close()
  p = tools.files({ cwd = fixture, query = "scroll.txt", preview = { max_size = 4 } })
  assert(vim.wait(5000, function()
    return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1]:find("too large") ~= nil
  end, 5))
  p:close()
  local file = assert(io.open(fixture .. "/binary.bin", "wb"))
  file:write("a\0b")
  file:close()
  p = tools.files({ cwd = fixture, query = "binary.bin" })
  assert(vim.wait(5000, function()
    return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1]:find("Binary file") ~= nil
  end, 5))
  p:close()
end)

test("late preview callbacks cannot overwrite a newer item or a closed picker", function()
  local requests, cancelled = {}, 0
  local p = tools.open({
    items = { "old", "new" },
    preview = { enabled = true },
    previewer = function(ctx)
      requests[#requests + 1] = ctx
      return function()
        cancelled = cancelled + 1
      end
    end,
  })
  p:move(1)
  requests[2].set_lines({ "new contents" })
  requests[1].set_lines({ "old contents" })
  drain()
  eq(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), { "new contents" })
  assert(requests[1].is_cancelled())
  p:close()
  eq(cancelled, 2)
  requests[2].set_lines({ "late contents" })
  drain()
end)

test("ui.select preview_item preserves external buffer ownership and highlights", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "second" })
  local ns = vim.api.nvim_create_namespace("fixture_preview")
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = 3, hl_group = "Search" })
  local p = tools.select({ "value" }, {
    preview_item = function()
      return { buf = buf, pos = { 2, 1 } }
    end,
  }, function() end)
  eq(vim.api.nvim_win_get_buf(p.preview_win), buf)
  eq(vim.api.nvim_win_get_cursor(p.preview_win), { 2, 1 })
  p:close()
  assert(vim.api.nvim_buf_is_valid(buf))
  eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 1)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("history is source-scoped, restores the draft, and persists when requested", function()
  local opts = {
    items = { "alpha", "beta" },
    source = "history_fixture",
    history = { persist = true, path = fixture .. "/history/history.json", limit = 2 },
  }
  local p = tools.open(opts)
  p:set_query("alpha")
  p:close()
  p = tools.open(opts)
  p:set_query("beta")
  p:close()
  p = tools.open(opts)
  p:set_query("draft")
  p:history_move(-1)
  eq(p.query, "beta")
  p:history_move(-1)
  eq(p.query, "alpha")
  p:history_move(1)
  p:history_move(1)
  eq(p.query, "draft")
  p:close()
  local saved = vim.json.decode(table.concat(vim.fn.readfile(opts.history.path), "\n"))
  eq(saved.history_fixture, { "beta", "draft" })
  opts.source = "other_history"
  p = tools.open(opts)
  p:history_move(-1)
  eq(p.query, "")
  p:close()
end)

test("copy and system-open use all marked paths without closing the picker", function()
  local a, b = { file = "first path" }, { file = "second path" }
  local opened, copied = {}, nil
  local p = tools.open({
    items = { a, b },
    multi = true,
    format_item = function(item)
      return item.file
    end,
    system_open = function(path)
      opened[#opened + 1] = path
      return true
    end,
  })
  p:toggle()
  p:move(1)
  p:toggle()
  local setreg = vim.fn.setreg
  vim.fn.setreg = function(register, value)
    eq(register, "+")
    copied = value
  end
  local ok, err = pcall(require("selection_tools.actions").copy, p)
  vim.fn.setreg = setreg
  assert(ok, err)
  eq(copied, "first path\nsecond path")
  require("selection_tools.actions").open(p)
  eq(opened, { "first path", "second path" })
  assert(not p.closed)
  p:close()
end)

vim.fn.delete(fixture, "rf")
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
