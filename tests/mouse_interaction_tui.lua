local configured = vim.env.SELECTION_TOOLS_CONFIGURED == "1"
if not configured then
  vim.opt.rtp:prepend(vim.fn.getcwd())
end
vim.o.swapfile = false
vim.o.mouse = "a"
vim.o.mousetime = 500
local api, tools = vim.api, require("selection_tools")
assert(
  debug.getinfo(require("selection_tools.mouse").setup, "S").source
    == "@" .. vim.fn.getcwd() .. "/lua/selection_tools/mouse.lua"
)
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local serial = 0
local function pause()
  local until_time = vim.uv.hrtime() + 100e6
  repeat
    coroutine.yield()
  until vim.uv.hrtime() >= until_time
end
local function wait(test, message)
  local started = vim.uv.hrtime()
  while not test() do
    assert((vim.uv.hrtime() - started) / 1e6 < 3000, message)
    coroutine.yield()
  end
end
local function mouse(win, row, code, count, col)
  vim.cmd.redraw()
  local pos = api.nvim_win_get_position(win)
  local x, y = pos[2] + (col or 8), pos[1] + row
  local press = ("\27[<%d;%d;%dM"):format(code or 0, x, y)
  local release = (code or 0) < 64 and ("\27[<%d;%d;%dm"):format(code or 0, x, y) or ""
  serial = serial + 1
  vim.fn.writefile({ (press .. release):rep(count or 1) }, directory .. "/mouse_input", "b")
  vim.fn.writefile({ "mouse_" .. serial }, directory .. "/stage")
  pause()
end
local function focused(p)
  assert(not p.closed, "mouse interaction unexpectedly closed the picker")
  assert(api.nvim_get_current_win() == p.input_win, "mouse must preserve input focus")
  assert(vim.fn.mode() == "i", "mouse must preserve Insert mode")
end
local function top(win)
  return api.nvim_win_call(win, function()
    return vim.fn.line("w0")
  end)
end
local function run()
  vim.cmd("enew!")
  local items, lines = {}, {}
  for index = 1, 120 do
    items[index] = { text = ("item %03d"):format(index) }
    lines[index] = "preview line " .. index
  end
  for _, reverse in ipairs({ false, true }) do
    local calls, guarded = 0, 0
    local p = tools.open({
      items = items,
      multi = true,
      resume = false,
      layout = { width = 0.8, height = 0.8, reverse = reverse, input_position = reverse and "bottom" or "top" },
      preview = { enabled = true },
      format_item = function(item)
        return item.text
      end,
      previewer = function(ctx)
        ctx.set_lines(lines)
      end,
      before_confirm = function()
        guarded = guarded + 1
        return true
      end,
      on_choice = function(item, index, selected)
        assert(item == items[117] and index == 117, "double click must preserve source identity")
        assert(#selected == 1 and selected[1] == items[3], "mouse marks must preserve source identity")
        calls = calls + 1
      end,
    })
    wait(function()
      return api.nvim_get_current_win() == p.input_win and vim.fn.mode() == "i" and p.preview.displayed
    end, "picker must be ready")
    local function row(index)
      for line, candidate in pairs(p.row_to_index) do
        if candidate == index then
          return line
        end
      end
      error("item is not visible: " .. index)
    end
    mouse(p.list_win, row(3))
    focused(p)
    assert(p.index == 3, "single click selects the screen row")
    mouse(p.list_win, row(3), 16) -- Ctrl+left toggles without moving to another item.
    assert(p.marks[3] and not p.marks[1])
    focused(p)
    local direction = reverse and 64 or 65
    mouse(p.list_win, row(3), direction)
    assert(p.index == 6, "wheel moves three candidates in screen order")
    focused(p)
    mouse(p.list_win, row(6), reverse and 65 or 64)
    assert(p.index == 3)
    p.index = 1
    p:_render()
    mouse(p.list_win, row(1), reverse and 65 or 64)
    assert(p.index == 1, "wheel at the edge must not wrap")
    local before = top(p.preview_win)
    mouse(p.preview_win, 2, 65)
    assert(top(p.preview_win) > before, "wheel scrolls the non-focusable preview")
    focused(p)
    mouse(p.preview_win, 3)
    focused(p)
    assert(p.index == 1, "preview clicks must not select an underlying list row")
    mouse(p.preview_win, 2, 64)
    assert(top(p.preview_win) == before)
    -- Clicks on the scrollbar and dividers must not reach the editor beneath.
    mouse(p.preview.scroll.win, 2, 65, 1, 1)
    focused(p)
    mouse(p.separator_wins[1], 1)
    focused(p)
    mouse(p.frame_win, api.nvim_win_get_height(p.frame_win) + 2, 0, 1, 1)
    focused(p)
    for _, pending in ipairs({ "matching", "finder_pending", "syntax_pending" }) do
      p[pending] = true
      mouse(p.list_win, row(3))
      assert(p.index == 1, "pending results must not accept mouse selection: " .. pending)
      p[pending] = false
    end
    -- A click after scrolling maps through the rendered offset, not source rank.
    p:move(30)
    local index = p.row_to_index[2]
    mouse(p.list_win, 2)
    assert(p.index == index and index > p.height)
    focused(p)
    p:set_query("item 117")
    mouse(p.list_win, reverse and 1 or p.height, 0, 2)
    assert(not p.closed and guarded == 0, "double clicking padding must not confirm")
    p:set_query("no matching item")
    mouse(p.list_win, 1, 0, 2)
    assert(not p.closed and guarded == 0, "double clicking no-results text must not confirm")
    p:set_query("item 117")
    for _ = 1, 6 do
      pause() -- Start a fresh double click after the no-results click sequence.
    end
    mouse(p.list_win, row(1), 0, 2)
    wait(function()
      return p.closed
    end, "double click must confirm")
    assert(calls == 1 and guarded == 1, "double click must use confirmation validation exactly once")
    assert(vim.fn.mode() == "n")
  end
  -- Search input clicks from Normal-mode list navigation resume editing.
  local p = tools.open({
    items = { "alpha", "beta" },
    resume = false,
    layout = { reverse = false },
    preview = { enabled = false },
  })
  wait(function()
    return vim.fn.mode() == "i"
  end, "input ready")
  vim.cmd.stopinsert()
  api.nvim_set_current_win(p.list_win)
  pause()
  mouse(p.list_win, 2)
  assert(p.index == 2 and vim.fn.mode() == "n", "Normal-mode clicks must select without entering Visual mode")
  mouse(p.input_win, 1)
  focused(p)
  p:close()
  assert(#api.nvim_list_wins() == 1, "mouse interaction must not leak windows")
end
local thread = coroutine.create(run)
local function step()
  local ok, err = coroutine.resume(thread)
  if not ok then
    vim.fn.writefile({ tostring(err), debug.traceback(thread) }, directory .. "/result")
    vim.cmd("cquit 1")
  elseif coroutine.status(thread) == "dead" then
    vim.fn.writefile(
      { "PASS mouse selection, marks, confirmation, scrolling, pending results, padding and input focus" },
      directory .. "/result"
    )
    vim.cmd("qa!")
  else
    vim.defer_fn(step, 10)
  end
end
vim.defer_fn(step, 30)
