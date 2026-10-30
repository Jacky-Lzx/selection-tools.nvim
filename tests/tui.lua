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

p = tools.select({ "beta", "betamax", "gamma" }, { prompt = "Terminal test" }, function(item, index)
  assert(item == "betamax" and index == 2, "terminal selection returned wrong item")
  assert(vim.api.nvim_get_current_win() == origin, "origin focus was not restored")
  stage = "open_cancel"
end)

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
