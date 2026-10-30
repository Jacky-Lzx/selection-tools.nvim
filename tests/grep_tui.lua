vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local path = directory .. "/help\t中文.rs"
vim.fn.writefile({ "\t中文 heldout_phase0 + help + heldout_phase1", "\t中文 help + heldout_phase2" }, path)
vim.api.nvim_set_hl(0, "Normal", { fg = "#cdd6f4", bg = "#1e1e2e" })
vim.api.nvim_set_hl(0, "Visual", { bg = "#6c7086" })
vim.api.nvim_set_hl(0, "Search", { bg = "#604482" })
local p = tools.grep({
  cwd = directory,
  regex = true,
  debounce_ms = 0,
  preview = { enabled = false },
  layout = { reverse = true, input_position = "bottom", width = 0.95 },
})
local function spans()
  return vim.tbl_filter(function(mark)
    return mark[4].hl_group == "SelectionToolsMatch"
  end, vim.api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true }))
end
local function check(regex)
  vim.cmd.redraw()
  local top, left = unpack(vim.api.nvim_win_get_position(p.list_win))
  local found = spans()
  assert(#found == 5, "Not all grep hits are highlighted")
  for _, mark in ipairs(found) do
    local row = mark[2]
    local line = vim.api.nvim_buf_get_lines(p.list_buf, row, row + 1, false)[1]
    local text = line:sub(mark[3] + 1, mark[4].end_col)
    assert(
      regex and (text == "help" or text:match("^heldout_phase%d$")) or not regex and text == "hel",
      "Wrong grep match range"
    )
    local filename
    for _, location in
      ipairs(vim.api.nvim_buf_get_extmarks(p.list_buf, -1, { row, 0 }, { row, -1 }, { details = true }))
    do
      if location[4].hl_group == "SelectionToolsFileLocation" then
        filename = location[3]
        break
      end
    end
    assert(filename, "Missing right-aligned file location")
    local match_col = left + vim.fn.strdisplaywidth(line:sub(1, mark[3])) + 1
    local plain_col = left + vim.fn.strdisplaywidth(line:sub(1, filename)) + 1
    assert(
      vim.fn.screenattr(top + row + 1, match_col) ~= vim.fn.screenattr(top + row + 1, plain_col),
      "Grep hit is not visible on screen"
    )
  end
  assert(p:matcher_status().backend == "none", "grep unexpectedly reran local matching")
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
      assert(ticks < 500, "Grep terminal timeout at " .. stage)
      if stage == "start" and not p.loading and vim.api.nvim_get_mode().mode == "i" then
        mark("type")
        stage = "typed"
      elseif stage == "typed" and p.query == "hel" and not p.loading then
        check(false)
        mark("move")
        stage = "moved"
      elseif stage == "moved" and p.index == 2 then
        check(false)
        p:set_query("heldout_phase[0-9]|help")
        stage = "regex"
      elseif stage == "regex" and not p.loading then
        check(true)
        p:set_query("not_found")
        stage = "empty"
      elseif stage == "empty" and not p.loading then
        assert(#p.matches == 0 and #spans() == 0, "Stale grep highlights survived")
        p:set_query("heldout_phase[0-9]|help")
        stage = "again"
      elseif stage == "again" and not p.loading then
        check(true)
        mark("confirm")
        stage = "chosen"
      elseif stage == "chosen" and p.closed then
        assert(vim.api.nvim_buf_get_name(0) == vim.uv.fs_realpath(path))
        assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
        finish(
          true,
          "PASS terminal live grep highlights: all literal and regex hits; selected rows; Unicode and tabs; stale query cleanup; file navigation"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
