local configured = vim.env.SELECTION_TOOLS_CONFIGURED == "1"
if not configured then
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
end
local api, tools = vim.api, require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
vim.o.swapfile = false
vim.cmd.enew()
local origin, source = api.nvim_get_current_win(), api.nvim_get_current_buf()
local lines = {}
for i = 1, 80 do
  lines[i] = string.rep("source text ", 20)
end
api.nvim_buf_set_lines(source, 0, -1, false, lines)
vim.wo.wrap = false

local function screen(row, col, width)
  local chars = {}
  for c = col, col + width - 1 do
    chars[#chars + 1] = vim.fn.screenstring(row, c)
  end
  return table.concat(chars)
end

local function finish(ok, message)
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end

vim.defer_fn(function()
  local p, stage, ticks = nil, "opening", 0
  local timer = assert(vim.uv.new_timer())
  local ok, err = xpcall(function()
    for _, position in ipairs({ "top", "bottom" }) do
      vim.cmd.redraw()
      local row, col = unpack(api.nvim_win_get_position(origin))
      -- Check the region the float will cover, away from status/tab bars.
      local before = screen(row + 10, col + 20, 40)
      assert(before:find("source text", 1, true))
      local frames = {}
      local function capture(event)
        vim.cmd.redraw()
        frames[#frames + 1] = { event, screen(row + 10, col + 20, 40) }
      end
      local group = api.nvim_create_augroup("SelectionOpeningTest", { clear = true })
      api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinNew" }, {
        group = group,
        callback = function(event)
          capture(event.event)
        end,
      })
      p = tools.open({
        prompt = "Opening test",
        items = { "first result", "second result" },
        preview = { enabled = true },
        preview_item = function()
          capture("preview provider")
          return { buf = source }
        end,
        layout = { height = 0.9, width = 0.8, input_position = position },
        on_change = function()
          capture("on_change")
        end,
      })
      api.nvim_del_augroup_by_id(group)
      assert(#frames >= 2, "Opening callbacks were not exercised")
      for _, frame in ipairs(frames) do
        assert(frame[2] == before, "Incomplete opening frame at " .. frame[1] .. ": " .. frame[2])
      end
      assert(api.nvim_get_current_win() == p.input_win)
      vim.cmd.redraw()
      local list_row, list_col = unpack(api.nvim_win_get_position(p.list_win))
      local first_row = p.opts.layout.reverse and list_row + p.height or list_row + 1
      assert(screen(first_row, list_col + 1, p.resolved.width):find("first result", 1, true))
      for i, divider in ipairs(p.resolved.separators) do
        assert(
          screen(p.resolved.frame.row + divider + 2, p.resolved.frame.col + 1, p.resolved.width + 2)
            == api.nvim_buf_get_lines(p.separator_buf, i - 1, i, false)[1],
          "The first visible frame is missing a divider"
        )
      end
      assert(p.preview.scroll.win, "Long initial preview should have a scrollbar")
      assert(not api.nvim_win_get_config(p.preview.scroll.win).hide, "Initial scrollbar stayed hidden")
      p:close()
      assert(api.nvim_get_current_win() == origin)
      assert(vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), lines))
    end
    local windows = #api.nvim_list_wins()
    local open_win = api.nvim_open_win
    local calls = 0
    api.nvim_open_win = function(...)
      calls = calls + 1
      if calls == 2 then
        error("opening failure")
      end
      return open_win(...)
    end
    local mounted, failure = pcall(tools.open, { items = { "failed" } })
    api.nvim_open_win = open_win
    assert(not mounted and tostring(failure):find("opening failure", 1, true))
    assert(#api.nvim_list_wins() == windows, "Failed construction leaked hidden windows")
    assert(api.nvim_get_current_win() == origin)

    p = tools.open({
      prompt = "Loading test",
      preview = { enabled = false },
      finder = function()
        -- Search may yield or redraw before returning its cancellation handle.
        vim.cmd.redraw()
        assert(vim.bo.filetype == "selection_tools_input")
        assert(not api.nvim_win_get_config(0).hide, "Finder ran before the input was visible")
      end,
    })
    stage = "insert"
  end, debug.traceback)
  if not ok then
    timer:close()
    finish(false, err)
    return
  end
  timer:start(
    10,
    10,
    vim.schedule_wrap(function()
      local valid, message = xpcall(function()
        ticks = ticks + 1
        assert(ticks < 400, "Opening terminal test timed out at " .. stage)
        if stage == "insert" and api.nvim_get_mode().mode == "i" then
          assert(p.loading and not p.closed)
          vim.cmd.redraw()
          local row, col = unpack(api.nvim_win_get_position(p.list_win))
          assert(screen(row + 1, col + 1, p.resolved.width):match("^%s*$"))
          vim.fn.writefile({ "type" }, directory .. "/stage")
          stage = "typed"
        elseif stage == "typed" and p.query == "bta" then
          assert(p.loading and api.nvim_get_current_win() == p.input_win)
          vim.fn.writefile({ "cancel" }, directory .. "/stage")
          stage = "cancelled"
        elseif stage == "cancelled" and p.closed then
          assert(api.nvim_get_current_win() == origin and api.nvim_get_mode().mode == "n")
          assert(vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), lines))
          timer:stop()
          timer:close()
          finish(
            true,
            "PASS opening frames: source preserved during preparation; complete overlay, preview and scrollbar; failed mount cleanup; typing and Escape while loading"
          )
        end
      end, debug.traceback)
      if not valid then
        timer:stop()
        timer:close()
        finish(false, message)
      end
    end)
  )
end, 150)
