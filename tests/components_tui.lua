vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local api, tools = vim.api, require("selection_tools")
local C = require("selection_tools.components")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local origin, source = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(source, 0, -1, false, { "original source" })
api.nvim_set_hl(0, "NormalFloat", { fg = "#dddddd", bg = "#112233" })
api.nvim_set_hl(0, "Visual", { bg = "#445566" })
api.nvim_set_hl(0, "Search", { bg = "#776600" })
local items = {
  {
    file = "深层目录/中文é_beta.lua",
    message = string.rep("context ", 20) .. "needle first tail",
    timestamp = 1,
  },
  { file = "other.lua", message = string.rep("中文é ", 20) .. "needle second tail", timestamp = 2 },
}
local p = tools.open({
  items = items,
  multi = true,
  components = {
    C.icon(),
    C.path({ path_format = false, max_width = 22, grow = 0 }),
    C.text({ field = "message", truncate = "match", grow = 1 }),
    C.time({ format = "%H:%M" }),
  },
  format_icon = function(item)
    return item == items[1] and "λ" or "🦀", "Special"
  end,
  layout = { width = 0.95, height = 0.8, reverse = true },
  keys = { select_previous = { "<Tab>" } },
})
local function check(expect_hit)
  vim.cmd.redraw()
  local top, left = unpack(api.nvim_win_get_position(p.list_win))
  local hits = 0
  for _, mark in ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
    local line = api.nvim_buf_get_lines(p.list_buf, mark[2], mark[2] + 1, false)[1]
    if mark[4].hl_group == "SelectionToolsMatch" then
      hits = hits + 1
      local cell = vim.fn.strwidth(line:sub(1, mark[3]))
      assert(
        vim.fn.screenstring(top + mark[2] + 1, left + cell + 1) == line:sub(mark[3] + 1, mark[3] + 1),
        "query highlight was not painted at its mapped cell"
      )
    end
  end
  if expect_hit then
    assert(hits >= 12, "visible query characters lost their highlights")
  end
  for row in pairs(p.row_to_index) do
    local line = api.nvim_buf_get_lines(p.list_buf, row - 1, row, false)[1]
    assert(vim.fn.strwidth(line) <= p.resolved.width, "components crossed the border")
  end
  assert(api.nvim_get_current_win() == p.input_win and api.nvim_get_mode().mode == "i")
  -- The default text style must inherit the selected background, even when
  -- NormalFloat has its own background.
  assert(not api.nvim_get_hl(0, { name = "SelectionToolsText", link = false }).bg)
end
local timer = assert(vim.uv.new_timer())
local stage, ticks, marked_item = "start", 0, nil
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function finish(ok, message)
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 600, "component TUI timed out at " .. stage)
      if stage == "start" and vim.api.nvim_get_mode().mode == "i" then
        check(false)
        mark("type")
        stage = "typed"
      elseif stage == "typed" and p.query == "needle" then
        check(true)
        marked_item = p:current()
        mark("select")
        stage = "selected"
      elseif stage == "selected" and #p:selected() == 1 then
        check(true)
        mark("resize_narrow")
        stage = "narrow"
      elseif stage == "narrow" and vim.o.columns == 48 then
        check(true)
        mark("resize_tiny")
        stage = "tiny"
      elseif stage == "tiny" and vim.o.columns == 16 then
        check(false)
        assert(p.query == "needle" and p:selected()[1] == marked_item)
        mark("resize_wide")
        stage = "wide"
      elseif stage == "wide" and vim.o.columns == 120 then
        check(true)
        mark("cancel")
        stage = "cancelled"
      elseif stage == "cancelled" and p.closed then
        assert(api.nvim_get_current_win() == origin)
        assert(api.nvim_buf_get_lines(source, 0, -1, false)[1] == "original source")
        finish(
          true,
          "PASS terminal components: Unicode clipping, query colors, wide icons, reverse rows, marks, narrow resizing and focus restoration"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
