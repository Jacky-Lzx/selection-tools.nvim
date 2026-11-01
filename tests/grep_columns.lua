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
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local function ready(p)
  assert(
    vim.wait(5000, function()
      return not p.loading and not p.matching and not p.syntax_pending
    end, 1),
    "source timed out"
  )
  assert(not p.error, p.error)
end
local function grouped(p, group)
  return vim.tbl_filter(function(mark)
    return mark[4].hl_group == group
  end, vim.api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true }))
end

test("code is left aligned with muted filenames and aligned trailing icons", function()
  vim.fn.writefile({ '    local needle = "value"' }, fixture .. "/one.lua")
  vim.fn.writefile({ '\treturn "needle"' }, fixture .. "/two.lua")
  local p = tools.grep({
    format_icon = function(item)
      return item.display_file == "one.lua" and "L" or "🦀", "Special"
    end,
    cwd = fixture,
    query = "needle",
    debounce_ms = 0,
    preview = { enabled = false },
    layout = {
      width = 0.95,
    },
  })
  ready(p)
  local locations = grouped(p, "SelectionToolsFileLocation")
  eq(#locations, 2)
  local icon_column
  for _, mark in ipairs(locations) do
    local label = vim.api.nvim_buf_get_lines(p.list_buf, mark[2], mark[2] + 1, false)[1]
    eq(vim.fn.strwidth(label), p.resolved.width)
    local icon = p.matches[p.row_to_index[mark[2] + 1]].grep_render.icon
    assert(icon and mark[4].end_col + 1 == icon.first)
    local cell = vim.fn.strwidth(label:sub(1, icon.first))
    icon_column = icon_column or cell
    eq(cell, icon_column)
    eq(cell, p.resolved.width - 2)
    local name = label:sub(mark[3] + 1, mark[4].end_col)
    assert(name:match("%.lua%s+1:%d+$"))
    assert(label:match("^local") or label:match("^return"))
  end
  local hl = vim.api.nvim_get_hl(0, { name = "SelectionToolsFileLocation", link = false })
  eq(hl.fg, vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg)
  assert(not hl.italic)
  p:toggle()
  for row, index in pairs(p.row_to_index) do
    local label = vim.api.nvim_buf_get_lines(p.list_buf, row - 1, row, false)[1]
    local prefix = p.marks[p.matches[index].index] and "● │ " or "○ │ "
    eq(label:sub(1, #prefix), prefix)
    eq(vim.fn.strwidth(label), p.resolved.width)
    local icon = p.matches[index].grep_render.icon
    eq(vim.fn.strwidth(label:sub(1, icon.first)), icon_column)
  end
  for _, hit in ipairs(grouped(p, "SelectionToolsMatch")) do
    local label = vim.api.nvim_buf_get_lines(p.list_buf, hit[2], hit[2] + 1, false)[1]
    eq(label:sub(hit[3] + 1, hit[4].end_col), "needle")
  end
  p:close()
end)

test("filenames and positions align independently when row and column digit counts differ", function()
  local util = require("selection_tools.sources.util")
  local items = {}
  for _, value in ipairs({
    { "same.lua", 11, 6 },
    { "same.lua", 4, 25 },
    { "same.lua", 1, 7 },
    { "更长的中文é文件名.lua", 12345, 999 },
    { "short.lua", 2, 9999 },
  }) do
    items[#items + 1] = util.location(value[1], value[2], value[3], "needle code", fixture)
  end
  local p = tools.open({
    items = items,
    result_layout = "grep",
    multi = true,
    format_item = util.format,
    syntax = { enabled = false },
    layout = { width = 0.95 },
  })
  local function aligned()
    local filename_end, position_start, position_end, shown
    for row, index in pairs(p.row_to_index) do
      local entry = p.matches[index]
      local display = entry.grep_render
      local text = vim.api.nvim_buf_get_lines(p.list_buf, row - 1, row, false)[1]
      assert(vim.fn.strwidth(text) <= p.resolved.width)
      if display.file then
        eq(vim.fn.strwidth(text), p.resolved.width)
        local ending = vim.fn.strwidth(text:sub(1, display.filename[2]))
        filename_end = filename_end or ending
        eq(ending, filename_end)
        if display.position then
          local start = vim.fn.strwidth(text:sub(1, display.position[1]))
          local finish = vim.fn.strwidth(text:sub(1, display.position[2]))
          position_start, position_end = position_start or start, position_end or finish
          eq(start, position_start)
          eq(finish, position_end)
          local value = text:sub(display.position[1] + 1, display.position[2]):gsub("^%s+", "")
          eq(value, ("%d:%d"):format(entry.item.pos[1], entry.item.pos[2] + 1))
          eq(start - ending, 2)
          shown = true
        else
          assert(not shown, "position column is hidden consistently")
        end
      end
    end
    return shown
  end
  assert(aligned(), "wide layout shows an independent position column")
  p:toggle()
  assert(aligned(), "selection markers preserve both metadata columns")
  for _, cells in ipairs({ 48, 25, 12, 75 }) do
    p.opts.layout.width = cells
    p:resize()
    aligned()
  end
  p:close()
end)

test("Unicode truncation respects cell budgets and composed character boundaries", function()
  local util = require("selection_tools.sources.util")
  local rows = require("selection_tools.grep_row")
  local old = vim.o.ambiwidth
  local ok, err = xpcall(function()
    for _, ambi in ipairs({ "single", "double" }) do
      vim.o.ambiwidth = ambi
      local code = "  " .. string.rep("中文é🦀", 15) .. "needle" .. string.rep("后缀", 12)
      local item = util.location(string.rep("目录/", 8) .. "组合é很长的文件名.lua", 123, 400, code)
      local entry = { item = item, text = item.text }
      local first = assert(item.text:find("needle", 1, true)) - 1
      local mark = "● │ "
      for cells = vim.fn.strwidth(mark), 120 do
        local meta = rows.file_width(cells - vim.fn.strwidth(mark), rows.info(entry).width + 3)
        local display = rows.render(
          entry,
          cells,
          meta,
          mark,
          { text = "🦀", hl = "Special" },
          { { first, first + 6 } }
        )
        assert(vim.fn.strwidth(display.text) <= cells, "overflow " .. vim.inspect({
          ambi = ambi,
          cells = cells,
          meta = meta,
          width = vim.fn.strwidth(display.text),
          text = display.text,
          info = rows.info(entry),
        }))
        local valid = pcall(vim.str_utfindex, display.text)
        assert(valid, "invalid UTF-8")
        if display.file then
          eq(vim.fn.strwidth(display.text), cells)
          if display.icon then
            eq(display.file[2] + 1, display.icon.first)
            eq(display.icon.last, #display.text)
          else
            eq(display.file[2], #display.text)
          end
          assert(not display.text:sub(display.file[1] + 1):match("^́"), "orphan combining mark")
        end
        for _, segment in ipairs(display.segments) do
          assert(segment[1] <= segment[2] and segment[3] + segment[2] - segment[1] <= #display.text)
        end
        if cells >= 40 then
          assert(display.text:find("needle", 1, true), "long-line match was hidden")
        end
      end
    end
  end, debug.traceback)
  vim.o.ambiwidth = old
  assert(ok, err)
end)

test("ellipsis mapping keeps query highlights on code and copies the complete path", function()
  local directory = fixture .. "/" .. string.rep("长目录", 12)
  vim.fn.mkdir(directory, "p")
  local path = directory .. "/very-long-file-name-中文.lua"
  vim.fn.writefile({ "\t" .. string.rep("prefix ", 25) .. "needle " .. string.rep("tail ", 15) }, path)
  local p = tools.grep({
    cwd = directory,
    query = "needle",
    debounce_ms = 0,
    preview = { enabled = false },
    layout = {
      width = 50,
    },
  })
  ready(p)
  local hits = grouped(p, "SelectionToolsMatch")
  eq(#hits, 1)
  local hit = hits[1]
  local label = vim.api.nvim_buf_get_lines(p.list_buf, hit[2], hit[2] + 1, false)[1]
  eq(label:sub(hit[3] + 1, hit[4].end_col), "needle")
  assert(label:find("…", 1, true))
  local location = grouped(p, "SelectionToolsFileLocation")[1]
  assert(hit[4].end_col <= location[3])
  eq(p:current().file, path)
  local setreg, copied = vim.fn.setreg, nil
  vim.fn.setreg = function(register, value)
    if register == "+" then
      copied = value
    else
      return setreg(register, value)
    end
  end
  local ok, err = pcall(require("selection_tools.actions").copy, p)
  vim.fn.setreg = setreg
  assert(ok, err)
  eq(copied, path)
  p:close()
end)

test("resizing recomputes columns and clipped matches without changing item identity", function()
  vim.fn.writefile({ string.rep("context ", 12) .. "needle " .. string.rep("suffix ", 12) }, fixture .. "/resize.lua")
  local p = tools.grep({
    cwd = fixture,
    query = "needle",
    debounce_ms = 0,
    preview = { enabled = false },
    layout = {
      width = 0.95,
    },
  })
  ready(p)
  local item = p:current()
  local columns = vim.o.columns
  local ok, err = xpcall(function()
    for _, size in ipairs({ 45, 25, 12, 100 }) do
      vim.o.columns = size
      vim.api.nvim_exec_autocmds("VimResized", {})
      assert(vim.wait(1000, function()
        return p.resolved.width == math.min(size - 4, math.floor(size * 0.95))
      end, 1))
      assert(p:current() == item)
      for _, line in ipairs(vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false)) do
        assert(vim.fn.strwidth(line) <= p.resolved.width)
      end
      for _, hit in ipairs(grouped(p, "SelectionToolsMatch")) do
        local line = vim.api.nvim_buf_get_lines(p.list_buf, hit[2], hit[2] + 1, false)[1]
        assert(("needle"):find(line:sub(hit[3] + 1, hit[4].end_col), 1, true))
      end
    end
  end, debug.traceback)
  vim.o.columns = columns
  p:close()
  assert(ok, err)
end)

vim.fn.delete(fixture, "rf")
print(("%d grep column tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
