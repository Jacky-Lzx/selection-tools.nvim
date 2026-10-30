vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
-- Catppuccin-style background-only groups reproduce the selected-row masking.
vim.api.nvim_set_hl(0, "Normal", { fg = "#cdd6f4", bg = "#1e1e2e" })
vim.api.nvim_set_hl(0, "Visual", { bg = "#6c7086" })
vim.api.nvim_set_hl(0, "Search", { bg = "#604482" })
vim.api.nvim_set_hl(0, "Comment", { fg = "#9399b2", italic = true, cterm = { italic = true } })
vim.api.nvim_set_hl(0, "SelectionToolsCount", { link = "Comment" })
local p = tools.open({
  items = { "Figures/New_idea.png", "Figures/other.png" },
  multi = true,
  format_icon = function()
    return "λ", "Special"
  end,
  layout = { reverse = true, input_position = "bottom" },
})
local function check()
  vim.cmd.redraw()
  local top, left = unpack(vim.api.nvim_win_get_position(p.list_win))
  local function attributes(index)
    local row = p.height - (index - p.offset) + 1
    local line = vim.api.nvim_buf_get_lines(p.list_buf, row - 1, row, false)[1]
    local function attr(text)
      local start = assert(line:find(text, 1, true))
      return vim.fn.screenattr(top + row, left + vim.fn.strdisplaywidth(line:sub(1, start - 1)) + 1)
    end
    return { plain = attr("Figures"), match = attr("pn"), eol = vim.fn.screenattr(top + row, left + p.resolved.width) }
  end
  local selected, other = attributes(p.index), attributes(p.index == 1 and 2 or 1)
  assert(selected.match ~= selected.plain, "Selected row masks the query highlight")
  assert(selected.plain ~= other.plain, "Selected row lost its background")
  assert(selected.match == other.match, "Selected match differs from the unselected match")
  assert(selected.eol == selected.plain, "Selection background does not extend to the edge")
  local count = vim.api.nvim_get_hl(0, { name = "SelectionToolsCount", link = false })
  assert(not count.italic and not (count.cterm and count.cterm.italic), "Count remains italic")
  assert(count.fg == 0x9399b2, "Count color changed")
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
      assert(ticks < 500, "Match terminal timeout at " .. stage)
      if stage == "start" and vim.api.nvim_get_mode().mode == "i" then
        mark("type")
        stage = "typed"
      elseif stage == "typed" and p.query == "png" and not p.matching then
        check()
        mark("move")
        stage = "moved"
      elseif stage == "moved" and p.index == 2 then
        check()
        if vim.fn.executable("sk") == 1 then
          p.matcher.opts.backend = "skim"
          p:set_query("pn")
          stage = "skim"
        else
          mark("cancel")
          stage = "closed"
        end
      elseif stage == "skim" and not p.matching then
        assert(p:matcher_status().backend == "skim")
        check()
        mark("cancel")
        stage = "closed"
      elseif stage == "closed" and p.closed then
        finish(
          true,
          "PASS terminal query highlights survive selected-row backgrounds, movement and matching backends; full-width selection and upright counters"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
