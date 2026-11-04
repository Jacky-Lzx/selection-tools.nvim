local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local configured = vim.env.SELECTION_TOOLS_CONFIGURED == "1"
if not configured then
  vim.opt.rtp:prepend(vim.fn.getcwd())
  vim.opt.rtp:prepend(vim.env.GIT_TOOLS_DIR or vim.fs.dirname(vim.fn.getcwd()) .. "/git-tools.nvim")
end
vim.o.swapfile = false
local api, tools = vim.api, require("selection_tools")
vim.cmd.enew()
api.nvim_buf_set_name(0, directory .. "/frames.lua")
local sequences = {}
for _, value in ipairs({ "one", "two", "three", "four" }) do
  vim.cmd("normal! i\007u\027gg0Clocal value = '" .. value .. "'\027")
  sequences[value] = vim.fn.undotree().seq_cur
end
local source, origin = api.nvim_get_current_buf(), api.nvim_get_current_win()
local original, tick = api.nvim_buf_get_lines(source, 0, -1, false), api.nvim_buf_get_changedtick(source)
local open_term, send, set_buffer = api.nvim_open_term, api.nvim_chan_send, api.nvim_win_set_buf
local channels, frames, blank, p = {}, {}, 0, nil
api.nvim_open_term = function(buf, opts)
  local channel = open_term(buf, opts)
  channels[channel], frames[buf] = buf, true
  return channel
end
-- Keep terminal input pending across several actual terminal redraws.
api.nvim_chan_send = function(channel, text)
  local buf = channels[channel]
  if not buf then
    return send(channel, text)
  end
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then
      send(channel, text)
    end
  end, 150)
end
api.nvim_win_set_buf = function(win, buf)
  if p and win == p.preview_win and buf ~= p.preview_buf then
    if not table.concat(api.nvim_buf_get_lines(buf, 0, -1, false)):find("%S") then
      blank = blank + 1
    end
  end
  return set_buffer(win, buf)
end
p = tools.undo({ compare = "current", backend = "delta" })
local stage, ticks, pending, prior = "start", 0, 0, nil
local timer = assert(vim.uv.new_timer())
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function finish(ok, text)
  timer:stop()
  timer:close()
  api.nvim_open_term, api.nvim_chan_send, api.nvim_win_set_buf = open_term, send, set_buffer
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
local function frame()
  return api.nvim_win_get_buf(p.preview_win)
end
local function ready(value)
  local item = p.preview.displayed_item
  return item
    and item.seq == sequences[value]
    and vim.bo[frame()].buftype == "terminal"
    and table.concat(api.nvim_buf_get_lines(frame(), 0, -1, false)):find(value, 1, true)
end
local function screen(expected)
  assert(blank == 0, "Delta published an empty terminal frame")
  assert(vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), original))
  assert(api.nvim_buf_get_changedtick(source) == tick)
  assert(api.nvim_get_current_win() == p.input_win and api.nvim_get_mode().mode == "i")
  vim.cmd.redraw()
  local config, chars = api.nvim_win_get_config(p.preview_win), {}
  for row = config.row + 1, config.row + config.height do
    for col = config.col + 1, config.col + config.width do
      chars[#chars + 1] = vim.fn.screenstring(row, col)
    end
  end
  local visible = table.concat(chars)
  assert(visible:find("%S"), "Preview became blank")
  assert(expected == "" or visible:find(expected, 1, true), "Ready preview disappeared while preparing a replacement")
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 600, "Delta frame timeout at " .. stage)
      assert(blank == 0, "Delta published an empty terminal frame")
      if stage == "start" and not p.loading and api.nvim_get_mode().mode == "i" then
        screen("Current version")
        mark("move")
        stage = "three"
      elseif stage == "three" and p:current().seq == sequences.three then
        if ready("three") then
          assert(pending >= 2, "No pending terminal frames exercised")
          screen("three")
          prior, pending = frame(), 0
          mark("move_again")
          stage = "two"
        else
          screen("Current version")
          pending = pending + 1
        end
      elseif stage == "two" and p:current().seq == sequences.two then
        assert(frame() == prior)
        screen("three")
        pending = pending + 1
        if pending == 2 then
          mark("move_latest")
          stage = "one"
        end
      elseif stage == "one" and p:current().seq == sequences.one then
        if ready("one") then
          screen("one")
          assert(not api.nvim_buf_is_valid(prior), "Old owned frame leaked")
          prior = frame()
          mark("resize_narrow")
          stage = "resize"
        else
          assert(frame() == prior)
          screen("three")
        end
      elseif stage == "resize" and vim.o.columns == 48 then
        screen("") -- Reflow can move a line outside the viewport while delta rerenders.
        if frame() ~= prior and ready("one") then
          screen("")
          assert(not api.nvim_buf_is_valid(prior))
          p:move(1)
          stage = "closing"
        end
      elseif stage == "closing" then
        screen("")
        for buf in pairs(frames) do
          if api.nvim_buf_is_valid(buf) and buf ~= frame() then
            mark("cancel")
            stage = "closed"
            break
          end
        end
      elseif stage == "closed" and p.closed and api.nvim_get_mode().mode == "n" then
        assert(api.nvim_get_current_win() == origin and api.nvim_get_current_buf() == source)
        for buf in pairs(frames) do
          assert(not api.nvim_buf_is_valid(buf), "Closing leaked a prepared or adopted frame")
        end
        finish(
          true,
          "PASS "
            .. (configured and "configured " or "")
            .. "delta frames: no blank adoption, old preview survives delayed ANSI, rapid cancellation, resize and close cleanup"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
