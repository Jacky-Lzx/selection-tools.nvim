vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local original = vim.api.nvim_get_current_win()
vim.api.nvim_set_hl(0, "SelectionIconLuaTest", { fg = "#123456" })
vim.api.nvim_set_hl(0, "SelectionIconPythonTest", { fg = "#cf3467" })
vim.api.nvim_set_hl(0, "Comment", { fg = "#778899" })
vim.api.nvim_set_hl(0, "Special", { fg = "#aabbcc" })
vim.api.nvim_set_hl(0, "Visual", { bg = "#303040" })
package.preload["nvim-web-devicons"] = function()
  return {
    get_icon = function(name)
      if name == "beta.lua" then
        return "λ", "SelectionIconLuaTest"
      end
      return "🦀", "SelectionIconPythonTest"
    end,
  }
end
local first, second =
  { text = "beta.lua", file = directory .. "/beta.lua" }, { text = "betamax.py", file = directory .. "/betamax.py" }
vim.fn.writefile({ "Lua preview" }, first.file)
vim.fn.writefile({ "Python preview" }, second.file)
local chosen, copied
local setreg = vim.fn.setreg
vim.fn.setreg = function(register, value, ...)
  if register == "+" then
    copied = value
    return 0
  end
  return setreg(register, value, ...)
end
local p = tools.open({
  items = { first, second },
  multi = true,
  preview = { enabled = true },
  layout = { height = 0.9, reverse = true, input_position = "bottom" },
  keys = { select_previous = { "<Tab>" }, copy = { "<C-y>" } },
  format_item = function(item)
    return item.text
  end,
  on_choice = function(item, index, selected)
    chosen = { item, index, selected }
  end,
})
local function check_screen(item, glyph, marked)
  vim.cmd.redraw()
  local top, left = unpack(vim.api.nvim_win_get_position(p.list_win))
  local row = top + p.height - (p.index - p.offset) + 1
  local prefix = marked and 4 or 1
  assert(vim.fn.screenstring(row, left + prefix) == " ", "Missing left icon padding")
  assert(vim.fn.screenstring(row, left + prefix + 1) == glyph, "Missing visible icon")
  assert(vim.fn.screenstring(row, left + prefix + 4) == "b", "File labels are not aligned")
  if marked then
    for display_row, index in pairs(p.row_to_index) do
      local entry = p.matches[index]
      local circle = p.marks[entry.index] and "●" or "○"
      assert(vim.fn.screenstring(top + display_row, left + 1) == circle, "Missing selection circle")
      assert(vim.fn.screenstring(top + display_row, left + 3) == "│", "Missing selection divider")
      local circle_attr = vim.fn.screenattr(top + display_row, left + 1)
      local divider_attr = vim.fn.screenattr(top + display_row, left + 3)
      assert((circle_attr ~= divider_attr) == not not p.marks[entry.index], "Incorrect selection circle color")
    end
    local function color(group)
      return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
    end
    assert(color("SelectionToolsMarked") == color("Special"), "Marked color does not follow theme")
    assert(color("SelectionToolsUnmarked") == color("Comment"), "Unmarked color does not follow theme")
    assert(color("SelectionToolsMarkSeparator") == color("Comment"), "Divider color does not follow theme")
  end
  local line = vim.api.nvim_buf_get_lines(p.list_buf, row - top - 1, row - top, false)[1]
  assert(line:find(item.text, 1, true))
  assert(vim.api.nvim_get_current_win() == p.input_win and vim.api.nvim_get_mode().mode == "i")
end
local function preview()
  return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1]
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
  vim.fn.setreg = setreg
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
      assert(ticks < 500, "Icon terminal timeout at " .. stage)
      local insert = vim.api.nvim_get_mode().mode == "i"
      if stage == "start" and insert and preview() == "Lua preview" then
        check_screen(first, "λ")
        mark("type")
        stage = "typed"
      elseif stage == "typed" and p.query == "bta" then
        assert(#p.matches == 2 and p:current() == first)
        check_screen(first, "λ")
        mark("move")
        stage = "moved"
      elseif stage == "moved" and p:current() == second and preview() == "Python preview" then
        check_screen(second, "🦀")
        mark("select")
        stage = "selected"
      elseif
        stage == "selected"
        and p:selected()[1] == second
        and p:current() == first
        and preview() == "Lua preview"
      then
        check_screen(first, "λ", true)
        vim.api.nvim_set_hl(0, "Comment", { fg = "#8899aa" })
        vim.api.nvim_set_hl(0, "Special", { fg = "#bbccdd" })
        check_screen(first, "λ", true)
        mark("unselect")
        stage = "unselected"
      elseif stage == "unselected" and #p:selected() == 0 and p:current() == first then
        check_screen(first, "λ", false)
        mark("reselect")
        stage = "reselected"
      elseif stage == "reselected" and p:selected()[1] == second and p:current() == first then
        check_screen(first, "λ", true)
        mark("copy")
        stage = "copied"
      elseif stage == "copied" and copied then
        assert(copied == second.file, "Icons contaminated copied paths")
        mark("confirm")
        stage = "confirmed"
      elseif stage == "confirmed" and chosen then
        assert(p.closed and chosen[1] == first and chosen[2] == 1 and chosen[3][1] == second)
        assert(vim.api.nvim_get_current_win() == original)
        finish(
          true,
          "PASS terminal colored item icons: narrow/wide glyph alignment; text-only fuzzy search; reversed rows; file previews; multiselect; clipboard paths; original selection identity"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
