vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local items = {}
for i, name in ipairs({ "first", "second", "third" }) do
  local path = directory .. "/" .. name .. ".txt"
  vim.fn.writefile({ name .. " preview contents", "another line" }, path)
  items[i] = { file = path }
end

-- Make each real file read span several terminal redraws.
local read = vim.uv.fs_read
vim.uv.fs_read = function(fd, size, offset, callback)
  return read(fd, size, offset, function(err, data)
    vim.defer_fn(function()
      callback(err, data)
    end, 180)
  end)
end

local p = tools.open({
  items = items,
  preview = { enabled = true },
  layout = { height = 0.9, input_position = "bottom" },
})
local stage, ticks, pending_frames = "first", 0, 0
local timer = assert(vim.uv.new_timer())
local finished = false
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function check_screen(expected)
  vim.cmd.redraw()
  local config = vim.api.nvim_win_get_config(p.preview_win)
  local chars = {}
  for col = config.col + 1, config.col + config.width do
    chars[#chars + 1] = vim.fn.screenstring(config.row + 1, col)
  end
  assert(table.concat(chars):find(expected, 1, true), "preview disappeared during a pending file read")
  assert(vim.api.nvim_get_current_win() == p.input_win and vim.api.nvim_get_mode().mode == "i")
end
timer:start(
  25,
  25,
  vim.schedule_wrap(function()
    if finished then
      return
    end
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 300, "preview terminal test timed out at " .. stage)
      local line = not p.closed and vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1]
      if stage == "first" and line == "first preview contents" then
        check_screen(line)
        mark("move")
        stage = "second"
      elseif stage == "second" and p.index == 2 then
        check_screen("first preview contents")
        pending_frames = pending_frames + 1
        if pending_frames == 3 then
          mark("move_again")
          stage = "third"
        end
      elseif stage == "third" and p.index == 3 then
        if line == "third preview contents" then
          check_screen(line)
          assert(pending_frames >= 6, "file read did not span enough redraws")
          mark("cancel")
          stage = "cancel"
        else
          check_screen("first preview contents")
          pending_frames = pending_frames + 1
        end
      elseif stage == "cancel" and p.closed then
        finished = true
      end
    end, debug.traceback)
    if not ok or finished then
      finished = true
      timer:stop()
      timer:close()
      vim.uv.fs_read = read
      p:close()
      vim.fn.writefile(
        vim.split(ok and "PASS terminal preview stays visible across slow reads and rapid item switches" or err, "\n"),
        directory .. "/result"
      )
      vim.cmd(ok and "qa!" or "cquit 1")
    end
  end)
)
