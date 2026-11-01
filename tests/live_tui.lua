vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
vim.fn.writefile({ "needle abc", "needle abx", "needle axx" }, directory .. "/sample.txt")
local p = tools.grep({
  cwd = directory,
  query = "needle ",
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
    local chars = {}
    for col = 1, vim.api.nvim_win_get_width(win) do
      chars[col] = vim.fn.screenstring(top + row, left + col)
    end
    lines[row] = table.concat(chars)
  end
  return lines
end
local function snapshot()
  vim.cmd.redraw()
  assert(vim.api.nvim_get_current_win() == p.input_win and vim.api.nvim_get_mode().mode == "i")
  return { screen(p.list_win), screen(p.preview_win) }
end
local function retained()
  assert(p.loading, "search completed before the pending frame was checked")
  assert(vim.deep_equal(snapshot(), displayed), "list or preview flickered during continuous input")
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(p.frame_buf, -1, 0, -1, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      assert(not chunk[1]:find("Loading") and not chunk[1]:find("Matching"), "pending label is visible")
    end
  end
  pending_frames = pending_frames + 1
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
      if stage == "ready" and not p.loading and p.preview.displayed and vim.api.nvim_get_mode().mode == "i" then
        assert(#p.matches == 3)
        displayed = snapshot()
        mark("type")
        stage = "a"
      elseif stage == "a" and p.query == "needle a" then
        retained()
        if pending_frames == 3 then
          mark("type_again")
          stage = "ab"
        end
      elseif stage == "ab" and p.query == "needle ab" then
        retained()
        if pending_frames == 6 then
          mark("type_last")
          stage = "abc"
        end
      elseif stage == "abc" and p.query == "needle abc" then
        if p.loading then
          retained()
        else
          assert(pending_frames >= 10, "not enough pending terminal frames were checked")
          assert(#p.matches == 1 and p:current().code == "needle abc")
          displayed = snapshot()
          mark("type_empty")
          stage = "empty"
        end
      elseif stage == "empty" and p.query == "needle abcx" then
        if p.loading then
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
      p:close()
      vim.fn.writefile(
        vim.split(
          ok
              and "PASS terminal live search retains list and preview during continuous typing; no loading labels; empty completion clears results"
            or err,
          "\n"
        ),
        directory .. "/result"
      )
      vim.cmd(ok and "qa!" or "cquit 1")
    end
  end)
)
