vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local path = directory .. "/test.lua"
vim.fn.writefile({ "local message = [[", 'print("needle")', "]]", 'local value = "needle"' }, path)
vim.api.nvim_set_hl(0, "Normal", { fg = "#cdd6f4", bg = "#1e1e2e" })
vim.api.nvim_set_hl(0, "Search", { bg = "#604482" })
-- Equal focus backgrounds let the screen compare syntax colors, not just capture names.
vim.api.nvim_set_hl(0, "SelectionToolsSelected", { bg = "#303040" })
vim.api.nvim_set_hl(0, "SelectionToolsPreviewLine", { bg = "#303040" })
vim.api.nvim_set_hl(0, "@string.lua", { fg = "#a6e3a1" })
vim.api.nvim_set_hl(0, "@keyword.lua", { fg = "#cba6f7" })
local p = tools.grep({
  cwd = directory,
  query = "needle",
  debounce_ms = 0,
  layout = { height = 0.9, reverse = true, input_position = "bottom" },
})
local function screen_attr(win, localrow, bytecol)
  local pos = vim.api.nvim_win_get_position(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local textoff = vim.fn.getwininfo(win)[1].textoff
  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), localrow - 1, localrow, false)[1]
  return vim.fn.screenattr(
    pos[1] + localrow - view.topline + 1,
    pos[2] + textoff + vim.fn.strdisplaywidth(line:sub(1, bytecol)) + 1
  )
end
local function check()
  vim.cmd.redraw()
  local item = p:current()
  local listrow = p.height - (p.index - p.offset) + 1
  local label = vim.api.nvim_buf_get_lines(p.list_buf, listrow - 1, listrow, false)[1]
  local codeword = item.pos[1] == 2 and "print" or "local"
  local start = assert(label:find(codeword, 1, true)) - 1
  local source = vim.api.nvim_buf_get_lines(p.preview_buf, item.pos[1] - 1, item.pos[1], false)[1]
  local original = assert(source:find(codeword, 1, true)) - 1
  local list_color = screen_attr(p.list_win, listrow, start)
  local body_color = screen_attr(p.preview_win, item.pos[1], original)
  assert(list_color == body_color, "Result code does not use the source Tree-sitter colors")
  local file
  for _, location in
    ipairs(vim.api.nvim_buf_get_extmarks(p.list_buf, -1, { listrow - 1, 0 }, { listrow - 1, -1 }, { details = true }))
  do
    if location[4].hl_group == "SelectionToolsFileLocation" then
      file = location[3]
      local display = p.matches[p.index].grep_render
      assert(location[4].end_col == (display.icon and display.icon.first - 1 or #label))
    end
  end
  assert(file and vim.fn.strwidth(label) == p.resolved.width, "File column is not right aligned")
  assert(list_color ~= screen_attr(p.list_win, listrow, file), "Result code is still plain text")
  local list_match = assert(label:find("needle", 1, true)) - 1
  local body_match = assert(source:find("needle", 1, true)) - 1
  local match_color = screen_attr(p.preview_win, item.pos[1], body_match)
  assert(match_color == screen_attr(p.list_win, listrow, list_match), "Preview match differs from result match")
  assert(match_color ~= body_color, "Preview match is not visible")
  local ns = vim.api.nvim_get_namespaces().selection_tools_preview_focus
  local found = false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(p.preview_buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == "SelectionToolsPreviewLine" then
      assert(mark[2] == item.pos[1] - 1)
      found = true
    end
  end
  assert(found, "Current result line is not marked")
  assert(vim.api.nvim_get_current_win() == p.input_win and vim.api.nvim_get_mode().mode == "i")
end
local stage, ticks, finished = "first", 0, false
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
      assert(ticks < 500, "Syntax terminal timeout at " .. stage)
      if p.closed then
        finish(
          true,
          "PASS terminal Tree-sitter code colors match source; multiline string context; current preview line and exact matches; moving results preserves input focus"
        )
        return
      end
      if
        p.loading
        or not p.syntax
        or not p.syntax.files[path]
        or p.syntax.pending[path]
        or not p.matches[p.index].syntax_source
        or p.preview.displayed_item ~= p:current()
        or vim.api.nvim_get_mode().mode ~= "i"
      then
        return
      end
      if stage == "first" then
        check()
        mark("move")
        stage = "second"
      elseif stage == "second" and p.index == 2 then
        check()
        mark("cancel")
        stage = "closed"
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
