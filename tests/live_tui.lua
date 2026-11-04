vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
vim.fn.writefile(
  { 'local needle_abc = "value"', 'local needle_abx = "value"', 'local needle_axx = "value"' },
  directory .. "/sample.lua"
)
vim.api.nvim_set_hl(0, "Normal", { fg = "#cdd6f4", bg = "#1e1e2e" })
vim.api.nvim_set_hl(0, "@keyword.lua", { fg = "#cba6f7" })
-- Span cold reads and cached metadata validation across multiple terminal frames.
local read, stat = vim.uv.fs_read, vim.uv.fs_stat
local function delay(callback)
  return function(err, value)
    vim.schedule(function()
      vim.defer_fn(function()
        callback(err, value)
      end, 100)
    end)
  end
end
vim.uv.fs_read = function(fd, size, offset, callback)
  return read(fd, size, offset, delay(callback))
end
vim.uv.fs_stat = function(path, callback)
  return stat(path, callback and delay(callback))
end
local p = tools.grep({
  cwd = directory,
  query = "needle_",
  debounce_ms = 250,
  layout = { height = 0.9, input_position = "bottom", reverse = true },
})
local stage, ticks, pending_frames = "ready", 0, 0
local displayed
local timer = assert(vim.uv.new_timer())
local finished = false
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function screen(win)
  local top, left = unpack(vim.api.nvim_win_get_position(win))
  local lines = {}
  for row = 1, vim.api.nvim_win_get_height(win) do
    local chars, attrs = {}, {}
    for col = 1, vim.api.nvim_win_get_width(win) do
      chars[col] = vim.fn.screenstring(top + row, left + col)
      attrs[col] = vim.fn.screenattr(top + row, left + col)
    end
    lines[row] = { table.concat(chars), attrs }
  end
  return lines
end
local function snapshot()
  vim.cmd.redraw()
  assert(vim.api.nvim_get_current_win() == p.input_win and vim.api.nvim_get_mode().mode == "i")
  return { screen(p.list_win), screen(p.preview_win) }
end
local function retained()
  -- A ready batch may be published before the process reports done. Only an
  -- unfinished replacement must retain the previous frame, not all loading.
  assert(p.finder_pending or p.syntax_pending, "replacement completed before the pending frame was checked")
  local current = snapshot()
  for pane = 1, 2 do
    for row, line in ipairs(current[pane]) do
      assert(
        vim.deep_equal(line, displayed[pane][row]),
        "pending frame changed at pane "
          .. pane
          .. " row "
          .. row
          .. ": "
          .. vim.inspect({ before = displayed[pane][row], after = line })
      )
    end
  end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(p.frame_buf, -1, 0, -1, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      assert(not chunk[1]:find("Loading") and not chunk[1]:find("Matching"), "pending label is visible")
    end
  end
  pending_frames = pending_frames + 1
end
local function colored()
  local found = 0
  local top, left = unpack(vim.api.nvim_win_get_position(p.list_win))
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
    if mark[4].hl_group == "@keyword.lua" then
      found = found + 1
      assert(
        vim.fn.screenattr(top + mark[2] + 1, left + mark[3] + 1)
          ~= vim.fn.screenattr(top + mark[2] + 1, left + mark[3] + 7),
        "keyword has no visible color"
      )
    end
  end
  assert(found == #p.matches, "a result row is missing syntax colors")
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
      assert(ticks < 500, "live terminal test timed out at " .. stage)
      if
        stage == "ready"
        and not p.loading
        and not p.syntax_pending
        and p.preview.displayed_item == p:current()
        and vim.api.nvim_get_mode().mode == "i"
      then
        assert(#p.matches == 3)
        displayed = snapshot()
        colored()
        mark("type")
        stage = "a"
      elseif stage == "a" and p.query == "needle_a" then
        retained()
        if pending_frames == 3 then
          mark("type_again")
          stage = "ab"
        end
      elseif stage == "ab" and p.query == "needle_ab" then
        retained()
        if pending_frames == 6 then
          mark("type_last")
          stage = "abc"
        end
      elseif stage == "abc" and p.query == "needle_abc" then
        if p.finder_pending or p.syntax_pending then
          retained()
        else
          if p.preview.displayed_item ~= p:current() then
            return
          end
          assert(pending_frames >= 10, "not enough pending terminal frames were checked")
          assert(#p.matches == 1 and p:current().code == 'local needle_abc = "value"')
          displayed = snapshot()
          colored()
          mark("type_empty")
          stage = "empty"
        end
      elseif stage == "empty" and p.query == "needle_abcx" then
        if p.finder_pending or p.syntax_pending then
          retained()
        else
          assert(#p.matches == 0)
          assert(vim.api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1] == "No results")
          mark("cancel")
          stage = "cancel"
        end
      elseif stage == "cancel" and p.closed then
        finished = true
      end
    end, debug.traceback)
    if not ok or finished then
      finished = true
      timer:stop()
      timer:close()
      vim.uv.fs_read, vim.uv.fs_stat = read, stat
      p:close()
      vim.fn.writefile(
        vim.split(
          ok
              and "PASS terminal continuous search retains list, preview and syntax colors through delayed reads and metadata checks; no loading labels; empty completion clears results"
            or err,
          "\n"
        ),
        directory .. "/result"
      )
      vim.cmd(ok and "qa!" or "cquit 1")
    end
  end)
)
