local configured = vim.env.SELECTION_TOOLS_CONFIGURED == "1"
if not configured then
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
end
local api = vim.api
local tools = require("selection_tools")
assert(
  debug.getinfo(require("selection_tools.picker").new, "S").source
    == "@" .. vim.fn.getcwd() .. "/lua/selection_tools/picker.lua"
)
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local labels = {
  top = {
    text = function(p)
      return "Title:" .. p.query
    end,
    align = "left",
  },
  middle = { text = "Path:目录_é", align = "center" },
  bottom = {
    text = function(p)
      return "Filter:" .. p.query
    end,
    align = "right",
  },
}
local p = tools.open({
  items = { "alpha", "beta" },
  preview = { enabled = true },
  layout = { width = 0.9, height = 0.9, input_position = "bottom", labels = labels },
})
local stage, ticks, iteration = "start", 0, 1
local alignments = { "left", "center", "right" }
local timer = assert(vim.uv.new_timer())
local function screen(row, col, width)
  local chars = {}
  for i = col, col + width - 1 do
    chars[#chars + 1] = vim.fn.screenstring(row, i)
  end
  return table.concat(chars)
end
local function check()
  vim.cmd.redraw()
  local frame, width = p.resolved.frame, p.resolved.width
  local actual = api.nvim_win_get_config(p.frame_win)
  local text = " Title:" .. p.query .. " "
  assert(actual.title[1][1] == text and actual.title_pos == p.opts.layout.labels.top.align)
  local top = screen(frame.row + 1, frame.col + 1, width + 2)
  local start = assert(top:find(text, 1, true), "Custom top title is not visible")
  local leading = vim.fn.strdisplaywidth(top:sub(1, start - 1))
  local alignment = p.opts.layout.labels.top.align
  if alignment == "left" then
    assert(leading < width / 3)
  elseif alignment == "center" then
    assert(math.abs(leading - (width + 2 - #text) / 2) <= 1)
  else
    assert(leading > width / 2)
  end
  local lines = api.nvim_buf_get_lines(p.separator_buf, 0, -1, false)
  for i, row in ipairs(p.resolved.separators) do
    local slot = i == 1 and "middle" or "bottom"
    local label = slot == "middle" and "Path:目录_é" or "Filter:" .. p.query
    local space = width - vim.fn.strdisplaywidth(label) - 2
    local align = p.opts.layout.labels[slot].align
    local before = align == "center" and math.floor(space / 2) or (align == "right" and space - 1 or 1)
    local expected = "├"
      .. string.rep("─", before)
      .. " "
      .. label
      .. " "
      .. string.rep("─", space - before)
      .. "┤"
    assert(lines[i] == expected)
    assert(
      screen(frame.row + row + 2, frame.col + 1, width + 2) == expected,
      "Custom divider is not visible at its row"
    )
  end
end
local function finish(ok, message)
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  30,
  30,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 300, "Label TUI timeout at " .. stage)
      if stage == "start" and api.nvim_get_mode().mode == "i" then
        check()
        for i, slot in ipairs({ "top", "middle", "bottom" }) do
          p.opts.layout.labels[slot].align = alignments[(iteration + i - 1) % 3 + 1]
        end
        p:resize()
        iteration = iteration + 1
        if iteration == 4 then
          check()
          vim.fn.writefile({ "type" }, directory .. "/stage")
          stage = "typed"
        end
      elseif stage == "typed" and p.query == "beta" then
        check()
        assert(#p.matches == 1 and api.nvim_get_current_win() == p.input_win)
        p:close()
        finish(
          true,
          "PASS "
            .. (configured and "configured " or "")
            .. "terminal border labels: independent left/center/right alignment, Unicode labels, dynamic typing and focus"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
