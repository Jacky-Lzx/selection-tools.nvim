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
      return not p.loading and not p.matching
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

test("code is left aligned while muted file locations end at the right edge", function()
  vim.fn.writefile({ '    local needle = "value"' }, fixture .. "/one.lua")
  vim.fn.writefile({ '\treturn "needle"' }, fixture .. "/two.lua")
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
  local locations = grouped(p, "SelectionToolsFileLocation")
  eq(#locations, 2)
  for _, mark in ipairs(locations) do
    local label = vim.api.nvim_buf_get_lines(p.list_buf, mark[2], mark[2] + 1, false)[1]
    eq(vim.fn.strwidth(label), p.resolved.width)
    eq(mark[4].end_col, #label)
    local name = label:sub(mark[3] + 1, mark[4].end_col)
    assert(name:match("%.lua:1:%d+$"))
    assert(label:match("^ local") or label:match("^ return"))
  end
  local hl = vim.api.nvim_get_hl(0, { name = "SelectionToolsFileLocation", link = false })
  eq(hl.fg, vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg)
  assert(not hl.italic)
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
      for cells = 4, 120 do
        local meta = rows.file_width(cells - 1, rows.info(entry).width + 3)
        local display = rows.render(
          entry,
          cells,
          meta,
          " ",
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
          eq(display.file[2], #display.text)
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
