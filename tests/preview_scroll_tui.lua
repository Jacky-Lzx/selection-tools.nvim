local configured = vim.env.SELECTION_TOOLS_CONFIGURED == "1"
if not configured then
  vim.opt.rtp:prepend(vim.fn.getcwd())
end
vim.opt.rtp:append(vim.env.GIT_TOOLS_DIR or vim.fs.dirname(vim.fn.getcwd()) .. "/git-tools.nvim")
vim.o.swapfile = false
vim.o.mouse = "a"
local api, tools = vim.api, require("selection_tools")
assert(
  debug.getinfo(require("selection_tools.picker").new, "S").source
    == "@" .. vim.fn.getcwd() .. "/lua/selection_tools/picker.lua"
)
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local diff_ok, diff = pcall(require, "git_tools.diff")
local delta = diff_ok and vim.fn.executable("delta") == 1
local content, after = {}, {}
for row = 1, 120 do
  content[row], after[row] = "old line " .. row, "new line " .. row
end
local p = tools.open({
  items = { "long", "short", "delta" },
  layout = { height = 0.9, width = 0.9, input_position = "bottom" },
  preview = { enabled = true },
  keys = not configured and { preview_down = { "<C-d>" }, preview_up = { "<C-u>" } } or nil,
  previewer = function(ctx)
    if ctx.item == "delta" and delta then
      return diff.render(ctx, diff.unified(content, after), {
        backend = "delta",
        cwd = directory,
        delta = { args = { "--file-style=omit" } },
      })
    end
    ctx.set_lines(ctx.item == "long" and content or { "short preview" })
  end,
})
local stage, ticks, expanded, prior_label = "start", 0, nil, nil
vim.keymap.set("i", "<C-g>", function()
  api.nvim_win_call(p.preview_win, function()
    vim.cmd("normal! gg")
  end)
end, { buffer = p.input_buf })
local timer = assert(vim.uv.new_timer())
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function label()
  return api.nvim_buf_get_lines(p.separator_buf, 0, 1, false)[1]
end
local function screen(row, col, width)
  local result = {}
  for cell = col, col + width - 1 do
    result[#result + 1] = vim.fn.screenstring(row, cell)
  end
  return table.concat(result)
end
local function check(overflow)
  assert(api.nvim_get_current_win() == p.input_win and api.nvim_get_mode().mode == "i")
  vim.cmd.redraw()
  local scroll = p.preview.scroll
  if overflow then
    assert(scroll.win and api.nvim_win_is_valid(scroll.win))
    local cfg = api.nvim_win_get_config(scroll.win)
    local thumb, track = 0, 0
    for row = cfg.row + 1, cfg.row + cfg.height do
      local char = screen(row, cfg.col + 1, 1)
      if char == "┃" then
        thumb = thumb + 1
      elseif char == "│" then
        track = track + 1
      else
        error("Scrollbar is not visible: " .. vim.inspect(char))
      end
    end
    assert(thumb > 0 and track > 0)
    local cfg = api.nvim_win_get_config(p.separator_wins[1])
    local actual = screen(cfg.row + 1, cfg.col + 1, cfg.width)
    assert(actual == label(), "Progress is not visible on the divider")
    assert(actual:find("%%"), "Missing percentage")
    assert(not actual:find("%d+/%d+"), "Progress should not show line numbers")
  else
    assert(not scroll.win and not label():find("%%"))
  end
end
local function finish(ok, message)
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  25,
  25,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 450, "Preview scroll TUI timeout at " .. stage)
      if stage == "start" and p.preview.displayed and api.nvim_get_mode().mode == "i" then
        check(true)
        assert(label():find("↓ 0%", 1, true))
        mark("scroll_down")
        stage = "middle"
      elseif stage == "middle" and label():find("↑↓", 1, true) then
        check(true)
        mark("scroll_bottom")
        stage = "bottom"
      elseif stage == "bottom" and label():find("↑ 100%", 1, true) then
        check(true)
        mark("scroll_up")
        stage = "up"
      elseif stage == "up" and label():find("↑↓", 1, true) then
        check(true)
        expanded = api.nvim_win_get_height(p.preview_win)
        mark("expand")
        stage = "expanded"
      elseif stage == "expanded" and api.nvim_win_get_height(p.preview_win) > expanded then
        check(true)
        mark("resize_narrow")
        stage = "narrow"
      elseif stage == "narrow" and vim.o.columns == 48 then
        check(true)
        mark("resize_wide")
        stage = "wide"
      elseif stage == "wide" and vim.o.columns == 120 then
        check(true)
        mark("collapse")
        stage = "collapsed"
      elseif stage == "collapsed" and api.nvim_win_get_height(p.preview_win) == expanded then
        check(true)
        mark("native_top")
        stage = "native"
      elseif stage == "native" and label():find("↓ 0%", 1, true) then
        check(true) -- A scroll outside the picker action must refresh progress.
        prior_label = label()
        -- Picker previews are non-focusable by default. Opt in for this native
        -- mouse-wheel check; the wheel must still keep focus in the input.
        api.nvim_win_set_config(p.preview_win, { focusable = true })
        local cfg = api.nvim_win_get_config(p.preview_win)
        vim.fn.writefile({ (cfg.col + 10) .. " " .. (cfg.row + 3) }, directory .. "/mouse")
        mark("scroll_mouse")
        stage = "mouse"
      elseif stage == "mouse" and label() ~= prior_label then
        check(true)
        mark("short")
        stage = "short"
      elseif stage == "short" and p.preview.displayed_item == "short" then
        check(false)
        if delta then
          mark("delta")
          stage = "delta"
        else
          mark("cancel")
          stage = "closed"
        end
      elseif stage == "delta" and vim.bo[api.nvim_win_get_buf(p.preview_win)].buftype == "terminal" then
        check(true)
        prior_label = label()
        mark("delta_scroll")
        stage = "delta_scroll"
      elseif stage == "delta_scroll" and label() ~= prior_label then
        check(true)
        assert(label():find("↑↓", 1, true))
        mark("cancel")
        stage = "closed"
      elseif stage == "closed" and p.closed then
        assert(not p.preview.scroll.win and not p.preview.scroll.buf)
        assert(api.nvim_get_current_win() == p.origin_win and api.nvim_get_mode().mode ~= "i")
        finish(
          true,
          "PASS preview scrollbar pixels and percentage: Ctrl-d/u, native/mouse scrolling, F3, resize, short content, "
            .. (delta and "real delta, " or "")
            .. "focus and cleanup"
            .. (configured and " (configured)" or "")
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
