vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.shadafile = "NONE"
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local p
local stage = "input"
local finished = false
local origin = vim.api.nvim_get_current_win()

local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end

p = tools.select({ "beta", "betamax", "gamma" }, {
  prompt = "Terminal test",
  preview = { enabled = true },
  previewer = function(ctx)
    ctx.set_lines({ "preview first line", "preview second line" }, nil, "hidden-filename.lua")
  end,
  layout = { height = 0.9, input_position = "bottom", reverse = true },
}, function(item, index)
  assert(item == "betamax" and index == 2, "terminal selection returned wrong item")
  assert(vim.api.nvim_get_current_win() == origin, "origin focus was not restored")
  stage = "open_cancel"
end)

local function screen(row, col, width)
  local chars = {}
  for i = col, col + width - 1 do
    chars[#chars + 1] = vim.fn.screenstring(row, i)
  end
  return table.concat(chars)
end

local function check_screen(count)
  vim.cmd.redraw()
  local frame = p.resolved.frame
  for _, row in ipairs(p.resolved.separators) do
    assert(
      screen(frame.row + row + 2, frame.col + 1, p.resolved.width + 2)
        == "├" .. string.rep("─", p.resolved.width) .. "┤",
      "divider does not join the frame or still contains a preview title"
    )
  end
  local input = vim.api.nvim_win_get_config(p.input_win)
  assert(
    screen(input.row + 1, frame.col + p.resolved.width - #count + 2, #count) == count,
    "count is not visible on the right of the input"
  )
  local preview = vim.api.nvim_win_get_config(p.preview_win)
  if #p.matches > 0 then
    assert(
      screen(preview.row + 1, preview.col + 1, 25):find("1 preview first line", 1, true),
      "preview line number missing"
    )
  end
end

local timer = vim.uv.new_timer()
local ticks = 0
timer:start(
  30,
  30,
  vim.schedule_wrap(function()
    if finished then
      return
    end
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 300, "TUI test timed out at " .. stage)
      if stage == "input" and vim.api.nvim_get_mode().mode == "i" then
        check_screen(" 3/3 ")
        mark("type_long")
        stage = "long_query"
      elseif stage == "long_query" and #p.query == 200 then
        check_screen(" 0/3 ")
        mark("type")
        stage = "filter"
      elseif stage == "filter" and p.query == "bta" then
        assert(#p.matches == 2, "typed query did not filter")
        assert(vim.api.nvim_get_mode().mode == "i", "typing left Insert mode")
        mark("move")
        stage = "move"
      elseif stage == "move" and p.index == 2 then
        mark("confirm")
        stage = "confirm"
      elseif stage == "open_cancel" then
        p = tools.select({ "cancel me" }, {}, function(item, index)
          assert(item == nil and index == nil, "Escape should cancel")
          stage = "done"
        end)
        stage = "wait_cancel"
      elseif stage == "wait_cancel" and vim.api.nvim_get_mode().mode == "i" then
        mark("cancel")
        stage = "cancel"
      elseif stage == "done" then
        assert(not vim.api.nvim_win_is_valid(p.input_win))
        assert(not vim.api.nvim_win_is_valid(p.list_win))
        assert(vim.api.nvim_get_current_win() == origin)
        finished = true
        timer:stop()
        timer:close()
        vim.fn.writefile(
          { "PASS terminal typing, fuzzy filtering, navigation, confirmation and Escape" },
          directory .. "/result"
        )
        vim.cmd("qa!")
      end
    end, debug.traceback)
    if not ok then
      finished = true
      timer:stop()
      timer:close()
      vim.fn.writefile({ err }, directory .. "/result")
      vim.cmd("cquit 1")
    end
  end)
)
