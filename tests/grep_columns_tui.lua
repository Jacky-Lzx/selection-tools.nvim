vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local file = "很长的文件名é_中文_document.lua"
vim.fn.writefile(
  { "\t" .. string.rep("中文é context ", 20) .. "needle " .. string.rep("tail ", 12) },
  directory .. "/" .. file
)
vim.api.nvim_set_hl(0, "Comment", { fg = "#888888" })
local p = tools.grep({
  cwd = directory,
  debounce_ms = 0,
  syntax = { enabled = false },
  preview = { enabled = false },
  layout = { width = 0.95, height = 0.8 },
})
local function check()
  vim.cmd.redraw()
  local row = p.opts.layout.reverse and p.height or 1
  local line = vim.api.nvim_buf_get_lines(p.list_buf, row - 1, row, false)[1]
  assert(vim.fn.strwidth(line) <= p.resolved.width, "Row crossed the right border")
  local hit, location
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
    if mark[4].hl_group == "SelectionToolsMatch" then
      hit = mark
    end
    if mark[4].hl_group == "SelectionToolsFileLocation" then
      location = mark
    end
  end
  assert(hit and line:sub(hit[3] + 1, hit[4].end_col) == "needle", "Ellipsis hid the query")
  local top, left = unpack(vim.api.nvim_win_get_position(p.list_win))
  local cell = left + vim.fn.strwidth(line:sub(1, hit[3])) + 1
  assert(vim.fn.screenstring(top + row, cell) == "n", "Hit is not visible on screen")
  if p.resolved.width - 1 >= 18 then
    local icon = p.matches[p.index].grep_render.icon
    assert(location and location[4].end_col == (icon and icon.first - 1 or #line))
    assert(vim.fn.strwidth(line) == p.resolved.width)
    if icon then
      assert(icon.last == #line, "Icon is not flush right")
    end
    assert(hit[4].end_col <= location[3], "Code overlaps the file column")
    local hl = vim.api.nvim_get_hl(0, { name = "SelectionToolsFileLocation", link = false })
    assert(hl.fg == 0x888888, "File column is not muted gray")
    assert(vim.fn.screenstring(top + row, left + p.resolved.width) ~= " ", "File column is not flush right")
  else
    assert(not location, "Tiny window should prioritize code")
  end
  assert(vim.api.nvim_get_current_win() == p.input_win and vim.api.nvim_get_mode().mode == "i")
end
local stage, ticks, finished = "start", 0, false
local timer = assert(vim.uv.new_timer())
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function finish(ok, message)
  finished = true
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    if finished then
      return
    end
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 600, "Column terminal timeout at " .. stage)
      if stage == "start" and not p.loading and vim.api.nvim_get_mode().mode == "i" then
        mark("type")
        stage = "typed"
      elseif stage == "typed" and p.query == "needle" and not p.loading then
        check()
        mark("resize_narrow")
        stage = "narrow"
      elseif stage == "narrow" and vim.o.columns == 48 and p.resolved.width == 44 then
        check()
        mark("resize_tiny")
        stage = "tiny"
      elseif stage == "tiny" and vim.o.columns == 16 and p.resolved.width == 12 then
        check()
        mark("resize_wide")
        stage = "wide"
      elseif stage == "wide" and vim.o.columns == 120 and p.resolved.width == 114 then
        check()
        mark("cancel")
        stage = "closed"
      elseif stage == "closed" and p.closed then
        finish(
          true,
          "PASS terminal grep columns: left code, gray right-aligned paths, Unicode ellipsis, visible query and live narrow/tiny/wide resizing"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
