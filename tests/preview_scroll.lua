vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.lines, vim.o.columns = 30, 100
local api, tools = vim.api, require("selection_tools")
local passed, failed = 0, 0
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function ready(p)
  assert(vim.wait(2000, function()
    return p.preview.displayed and p.preview.displayed_item == p:current() and not p.loading and not p.matching
  end, 2))
  p:_draw_separators()
end
local function lines(count)
  local result = {}
  for row = 1, count do
    result[row] = "line " .. row
  end
  return result
end
local function open(extra)
  return tools.open(vim.tbl_deep_extend("force", {
    items = { "long", "short" },
    preview = { enabled = true },
    layout = { height = 0.9, width = 0.9 },
    previewer = function(ctx)
      ctx.set_lines(lines(ctx.item == "long" and 120 or 1))
    end,
  }, extra or {}))
end
local function divider(p)
  local index = p.opts.layout.input_position == "bottom" and 1 or 2
  return api.nvim_buf_get_lines(p.separator_buf, index - 1, index, false)[1]
end
local function test(name, fn)
  local windows = api.nvim_list_wins()
  local ok, err = xpcall(fn, debug.traceback)
  for _, win in ipairs(api.nvim_list_wins()) do
    if not vim.tbl_contains(windows, win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  vim.o.lines, vim.o.columns = 30, 100
  tools.setup()
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end

test("scroll indicators follow top, middle and end without taking focus or content width", function()
  for _, position in ipairs({ "top", "bottom" }) do
    local p = open({ layout = { input_position = position } })
    ready(p)
    local scroll = p.preview.scroll
    local config = api.nvim_win_get_config(scroll.win)
    eq(config.width, 1)
    eq(config.focusable, false)
    eq(config.col, api.nvim_win_get_position(p.preview_win)[2] + p.resolved.width)
    eq(api.nvim_win_get_width(p.preview_win), p.resolved.width)
    assert(divider(p):find("↓ 0%", 1, true))
    local initial = api.nvim_buf_get_lines(scroll.buf, 0, -1, false)
    eq(initial[1], "┃")
    local input = api.nvim_get_current_win()
    p:scroll_preview(1)
    eq(api.nvim_get_current_win(), input)
    assert(divider(p):find("↑↓", 1, true))
    for _ = 1, 30 do
      p:scroll_preview(1)
    end
    local label = divider(p)
    assert(label:find("↑", 1, true) and not label:find("↓", 1, true))
    assert(label:find("100%", 1, true))
    eq(api.nvim_buf_get_lines(scroll.buf, -2, -1, false)[1], "┃")
    local buf, win = scroll.buf, scroll.win
    p:close()
    assert(not api.nvim_buf_is_valid(buf) and not api.nvim_win_is_valid(win))
  end
end)

test("position reserves space beside Unicode titles at every alignment and on narrow screens", function()
  for _, border in ipairs({ "rounded", "double", "none" }) do
    for _, align in ipairs({ "left", "center", "right" }) do
      local p =
        open({ layout = { border = border, labels = { bottom = { text = "目录_é_预览", align = align } } } })
      ready(p)
      assert(divider(p):find("目录_é_预览", 1, true))
      assert(divider(p):find("0%", 1, true))
      vim.o.columns = 16
      p:resize()
      for _, line in ipairs(api.nvim_buf_get_lines(p.separator_buf, 0, -1, false)) do
        eq(vim.fn.strdisplaywidth(line), p.resolved.width + (border == "none" and 0 or 2))
      end
      p:close()
      vim.o.columns = 100
    end
  end
end)

test("short, empty and explicitly non-scrollable frames hide both indicators", function()
  local context
  local p = open({
    previewer = function(ctx)
      context = ctx
      ctx.set_lines(lines(120))
    end,
  })
  ready(p)
  local buf = p.preview.scroll.buf
  assert(context.paint(function(target)
    api.nvim_buf_set_lines(target, 0, -1, false, lines(120))
  end, { scrollable = false }))
  eq(p.preview.scroll.win, nil)
  assert(not divider(p):find("%", 1, true))
  context.set_lines(lines(120))
  assert(vim.wait(1000, function()
    return p.preview.scroll.win ~= nil
  end, 2))
  context.set_lines({ "short" })
  assert(vim.wait(1000, function()
    return not p.preview.scroll.win
  end, 2))
  assert(not divider(p):find("%", 1, true))
  context.set_lines({})
  vim.wait(10)
  eq(p.preview.scroll.win, nil)
  p:close()
  assert(not api.nvim_buf_is_valid(buf))
end)

test("borrowed and terminal buffers use their own content and remain untouched", function()
  for _, terminal in ipairs({ false, true }) do
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    local channel
    if terminal then
      channel = api.nvim_open_term(buf, {})
      api.nvim_chan_send(channel, table.concat(lines(120), "\r\n"))
      assert(vim.wait(1000, function()
        return api.nvim_buf_line_count(buf) >= 120
      end, 2))
    else
      api.nvim_buf_set_lines(buf, 0, -1, false, lines(120))
    end
    local ns = api.nvim_create_namespace("scroll_borrowed")
    api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 4, hl_group = "Search" })
    local p = tools.select({ "borrowed" }, {
      layout = { height = 0.9, width = 0.9 },
      preview_item = function()
        return { buf = buf, pos = { 1, 0 } }
      end,
    }, function() end)
    ready(p)
    local content, tick = api.nvim_buf_get_lines(buf, 0, -1, false), api.nvim_buf_get_changedtick(buf)
    local marks = api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    assert(p.preview.scroll.win)
    p:scroll_preview(1)
    assert(divider(p):find("↑↓", 1, true))
    eq(api.nvim_buf_get_changedtick(buf), tick)
    eq(api.nvim_buf_get_lines(buf, 0, -1, false), content)
    eq(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true }), marks)
    p:close()
    assert(api.nvim_buf_is_valid(buf))
    api.nvim_buf_delete(buf, { force = true })
  end
end)

test("pending replacement keeps the old progress and late deliveries cannot restore it", function()
  local pending
  local p = open({
    previewer = function(ctx)
      if ctx.item == "long" then
        ctx.set_lines(lines(120))
      else
        pending = ctx
      end
    end,
  })
  ready(p)
  p:scroll_preview(1)
  local label, win = divider(p), p.preview.scroll.win
  p:move(1)
  eq(divider(p), label)
  eq(p.preview.scroll.win, win)
  pending.set_lines({ "ready short replacement" })
  assert(vim.wait(1000, function()
    return not p.preview.scroll.win
  end, 2))
  p:move(1)
  ready(p)
  local current = divider(p)
  pending.set_lines(lines(300))
  vim.wait(10)
  eq(divider(p), current)
  p:close()
end)

test("resume, expand and preview disappearance refresh and clean up the scrollbar", function()
  local p = open()
  ready(p)
  p:scroll_preview(1)
  local before = divider(p)
  p:close()
  p = tools.resume()
  ready(p)
  eq(divider(p), before)
  local height = api.nvim_win_get_height(p.preview.scroll.win)
  p:expand_preview()
  assert(api.nvim_win_get_height(p.preview.scroll.win) > height)
  p:expand_preview()
  eq(api.nvim_win_get_height(p.preview.scroll.win), height)
  local old = p.preview.scroll.win
  vim.o.lines = 9
  p:resize()
  eq(p.preview_win, nil)
  assert(not api.nvim_win_is_valid(old))
  vim.o.lines = 30
  p:resize()
  ready(p)
  assert(p.preview.scroll.win)
  p:close()
end)

test("scrollbar and position can be disabled independently", function()
  for _, opts in ipairs({ { scrollbar = false }, { position = false }, { scrollbar = false, position = false } }) do
    local p = open({ preview = opts })
    ready(p)
    eq(p.preview.scroll.win ~= nil, opts.scrollbar ~= false)
    eq(divider(p):find("%", 1, true) ~= nil, opts.position ~= false)
    p:close()
  end
end)

test("both file and loaded-buffer limits advertise truncation even when the preview fits", function()
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile(lines(120), path)
  local buf = vim.fn.bufadd(path)
  for _, loaded in ipairs({ false, true }) do
    if loaded then
      vim.fn.bufload(buf)
    end
    local p = tools.open({ items = { { file = path } }, preview = { enabled = true, max_lines = 3 } })
    assert(vim.wait(2000, function()
      return p.preview.truncated
    end, 2))
    eq(p.preview.scroll.win, nil)
    assert(divider(p):find("truncated", 1, true))
    p:close()
  end
  api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end)

print(("%d preview scroll tests passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cquit 1")
