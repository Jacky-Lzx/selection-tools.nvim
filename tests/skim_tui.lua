vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local configured = vim.env.SELECTION_TOOLS_CONFIG_TEST == "1"
if not configured then
  tools.setup({
    layout = { input_position = "bottom", reverse = true, height = 0.9 },
    keys = { select_previous = { "<Tab>" } },
  })
end
vim.fn.writefile({ "beta preview" }, directory .. "/beta.txt")
vim.fn.writefile({ "betamax preview" }, directory .. "/betamax.txt")
local stage, ticks, heartbeat = "startup", 0, 0
local picker, chosen, cancelled
local origin = vim.api.nvim_get_current_win()
local items = {}
for i = 1, 60000 do
  items[i] = { text = "entry" .. i }
end
local beta = { text = "beta", file = directory .. "/beta.txt", run = function() end }
local betamax = { text = "betamax", file = directory .. "/betamax.txt" }
items[60001], items[60002] = beta, betamax
local timer = assert(vim.uv.new_timer())
local finished = false
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function finish(ok, message)
  if finished then
    return
  end
  finished = true
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  5,
  5,
  vim.schedule_wrap(function()
    if finished then
      return
    end
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 2000, "skim terminal test timed out at " .. stage)
      if picker and picker.matching then
        heartbeat = heartbeat + 1
        assert(#picker.matches > 0, "visible results were cleared while matching")
        local lines = vim.api.nvim_buf_get_lines(picker.list_buf, 0, -1, false)
        assert(#lines > 0 and not vim.tbl_contains(lines, "Matching…"), "matching placeholder replaced the list")
      end
      if stage == "startup" and (not configured or vim.g.did_very_lazy) then
        picker = tools.open({
          items = items,
          multi = true,
          preview = { enabled = true },
          format_item = function(item)
            return item.text
          end,
          on_choice = function(item, index, selected)
            chosen = { item, index, selected }
          end,
        })
        stage = "input"
      elseif stage == "input" and vim.api.nvim_get_mode().mode == "i" then
        mark("prefix")
        stage = "prefix"
      elseif stage == "prefix" and picker.query == "b" then
        mark("suffix")
        stage = "filter"
      elseif stage == "filter" and picker.query == "bta" and not picker.matching then
        assert(picker:matcher_status().backend == "skim")
        assert(#picker.matches == 2 and picker:current() == beta)
        assert(heartbeat > 0, "event loop did not run during matching")
        assert(vim.api.nvim_get_mode().mode == "i")
        assert(vim.api.nvim_get_current_win() == picker.input_win)
        if vim.api.nvim_buf_get_lines(picker.preview_buf, 0, 1, false)[1] == "beta preview" then
          mark("move")
          stage = "move"
        end
      elseif stage == "move" and picker:current() == betamax then
        if vim.api.nvim_buf_get_lines(picker.preview_buf, 0, 1, false)[1] == "betamax preview" then
          mark("select")
          stage = "select"
        end
      elseif stage == "select" and picker:selected()[1] == betamax and picker:current() == beta then
        mark("confirm")
        stage = "confirm"
      elseif stage == "confirm" and chosen then
        assert(chosen[1] == beta and chosen[2] == 60001 and chosen[3][1] == betamax)
        assert(picker.closed and vim.api.nvim_get_current_win() == origin)
        picker = tools.select({ "cancel" }, {}, function(item, index)
          cancelled = { item, index }
        end)
        picker:set_query("can")
        assert(picker:matcher_status().backend == "native")
        stage = "cancel_input"
      elseif stage == "cancel_input" and vim.api.nvim_get_mode().mode == "i" then
        mark("cancel")
        stage = "cancel"
      elseif stage == "cancel" and cancelled then
        assert(cancelled[1] == nil and cancelled[2] == nil and picker.closed)
        assert(vim.api.nvim_get_current_win() == origin)
        if configured then
          assert(#_G.config_test_errors == 0, table.concat(_G.config_test_errors, "\n"))
        end
        finish(
          true,
          "PASS terminal auto matcher: 60,002 items; continuous input; live event loop; skim results; file preview; selection identity; native small-list fallback; Escape"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
