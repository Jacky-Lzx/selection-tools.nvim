local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local configured = vim.env.SELECTION_TOOLS_CONFIGURED == "1"
if not configured then
  vim.opt.rtp:prepend(vim.fn.getcwd())
  vim.opt.rtp:prepend(vim.env.GIT_TOOLS_DIR or vim.fs.dirname(vim.fn.getcwd()) .. "/git-tools.nvim")
  vim.g.mapleader = " "
  vim.keymap.set("n", "<leader>su", function()
    require("selection_tools").undo()
  end)
end
vim.o.swapfile = false
local api = vim.api
local tools = require("selection_tools")
assert(vim.fn.executable("delta") == 1)
assert(vim.fn.maparg(" su", "n") ~= "", "Space su is not mapped")
assert(
  debug.getinfo(require("selection_tools.sources.undo"), "S").source
    == "@" .. vim.fn.getcwd() .. "/lua/selection_tools/sources/undo.lua"
)

vim.cmd.enew()
api.nvim_buf_set_name(0, directory .. "/状态_é.lua")
vim.bo.filetype = "lua"
vim.cmd("normal! ilocal value = '旧版本'\027")
vim.cmd("silent write")
local saved_seq = vim.fn.undotree().seq_cur
vim.cmd("normal! i\007u\027gg0Clocal value = '旧分支'\027")
local old_seq = vim.fn.undotree().seq_cur
local old_lines = api.nvim_buf_get_lines(0, 0, -1, false)
vim.cmd("silent undo " .. saved_seq)
vim.cmd("normal! i\007u\027gg0Clocal value = '新版本'\027")
local source, origin = api.nvim_get_current_buf(), api.nvim_get_current_win()
local lines, tick = api.nvim_buf_get_lines(source, 0, -1, false), api.nvim_buf_get_changedtick(source)
local p
local undo = tools.undo
tools.undo = function(opts)
  p = undo(opts)
  return p
end
local stage, ticks, finished, frame = "open", 0, false, nil
local timer = assert(vim.uv.new_timer())
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function finish(ok, message)
  finished = true
  timer:stop()
  timer:close()
  tools.undo = undo
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
local function preview()
  return api.nvim_win_get_buf(p.preview_win)
end
local function delta()
  return vim.bo[preview()].buftype == "terminal"
    and table.concat(api.nvim_buf_get_lines(preview(), 0, -1, false), ""):find("value", 1, true)
end
local function check()
  assert(vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), lines))
  assert(api.nvim_buf_get_changedtick(source) == tick)
  assert(api.nvim_get_current_win() == p.input_win and api.nvim_get_mode().mode == "i")
  vim.cmd.redraw()
  local top, left = unpack(api.nvim_win_get_position(p.list_win))
  for row, index in pairs(p.row_to_index) do
    local item = p.matches[index].item
    local line = api.nvim_buf_get_lines(p.list_buf, row - 1, row, false)[1]
    assert(vim.fn.strdisplaywidth(line) == p.resolved.width, "Undo row is not the full window width")
    assert(line:sub(-#item.sequence) == item.sequence, "Sequence is not flush right")
    local col = left + vim.fn.strdisplaywidth(item.text:sub(1, item.node_byte)) + 1
    assert(
      vim.fn.screenstring(top + row, col) == (item.current and "◆" or "●"),
      "Graph node is not visible on its row"
    )
    local sequence_mark, time_mark
    for _, mark in
      ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, { row - 1, 0 }, { row - 1, -1 }, { details = true }))
    do
      local text = line:sub(mark[3] + 1, mark[4].end_col or mark[3])
      sequence_mark = sequence_mark or mark[4].hl_group == "Comment" and text == item.sequence
      time_mark = time_mark or mark[4].hl_group == "Number" and text == item.timestamp
    end
    assert(sequence_mark, "Sequence lost the muted time style")
    if p.resolved.width >= 44 and not item.context then
      assert(time_mark, "Time lost the primary sequence style")
    end
  end
  for i, win in ipairs(p.separator_wins) do
    local line = api.nvim_buf_get_lines(p.separator_buf, i - 1, i, false)[1]
    local config = api.nvim_win_get_config(win)
    assert(vim.fn.strdisplaywidth(line) == config.width, "Divider crossed border")
    local screen = {}
    for col = config.col + 1, config.col + config.width do
      screen[#screen + 1] = vim.fn.screenstring(config.row + 1, col)
    end
    assert(table.concat(screen) == line, "Divider title is not visible at its own row")
  end
end
mark("open")
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    if finished then
      return
    end
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(
        ticks < 600,
        "Undo terminal timeout at "
          .. stage
          .. "; expected "
          .. old_seq
          .. "; current "
          .. vim.inspect(p and p:current())
      )
      if stage == "open" and p and not p.loading and api.nvim_get_mode().mode == "i" then
        assert(p:current().current)
        local fork, parent
        for _, entry in ipairs(p.entries) do
          if entry.item.seq == old_seq then
            fork = entry.item
          elseif entry.item.seq == saved_seq then
            parent = entry.item
          end
        end
        assert(
          fork and fork.parent == saved_seq and parent.graph:find("●─╯", 1, true),
          "The fork must leave the shared ancestor's row"
        )
        check()
        mark("move")
        stage = "delta"
      elseif stage == "delta" and p:current().seq == old_seq and delta() then
        assert(p.opts.compare == "parent" and p.preview_title:find("Step #", 1, true))
        check()
        mark("compare_current")
        stage = "current_mode"
      elseif
        stage == "current_mode"
        and p.opts.compare == "current"
        and p.preview_title:find("Current #", 1, true)
        and delta()
      then
        assert(p:current().seq == old_seq and p.query == "")
        assert(table.concat(api.nvim_buf_get_lines(preview(), 0, -1, false)):find("新版本", 1, true))
        check()
        mark("compare_parent")
        stage = "parent_mode"
      elseif
        stage == "parent_mode"
        and p.opts.compare == "parent"
        and p.preview_title:find("Step #", 1, true)
        and delta()
      then
        assert(p:current().seq == old_seq and p.query == "")
        assert(not table.concat(api.nvim_buf_get_lines(preview(), 0, -1, false)):find("新版本", 1, true))
        check()
        mark("filter")
        stage = "filtered"
      elseif stage == "filtered" and p.query == "saved" and not p.loading then
        assert(#p.matches == 2 and p.matches[1].item.saved and p.matches[2].item.context)
        assert(p.matches[1].item.graph == "● " and p.matches[2].item.graph == "● ")
        check()
        frame = preview()
        mark("zero")
        stage = "zero"
      elseif stage == "zero" and #p.matches == 0 and preview() == p.preview_buf then
        assert(not api.nvim_buf_is_valid(frame) and not p.closed)
        check()
        mark("clear")
        stage = "clear"
      elseif stage == "clear" and p.query == "" and #p.matches > 0 then
        mark("move_again")
        stage = "restored"
      elseif stage == "restored" and p:current().seq == old_seq and delta() then
        frame = preview()
        mark("resize_narrow")
        stage = "narrow"
      elseif stage == "narrow" and vim.o.columns == 48 and delta() and preview() ~= frame then
        check()
        frame = preview()
        mark("resize_tiny")
        stage = "tiny"
      elseif stage == "tiny" and vim.o.columns == 16 and delta() and preview() ~= frame then
        check()
        frame = preview()
        mark("resize_wide")
        stage = "wide"
      elseif stage == "wide" and vim.o.columns == 120 and delta() and preview() ~= frame then
        check()
        mark("cancel")
        stage = "cancelled"
      elseif stage == "cancelled" and p.closed and api.nvim_get_mode().mode == "n" then
        assert(api.nvim_get_current_win() == origin and api.nvim_get_current_buf() == source)
        assert(vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), lines))
        mark("reopen")
        stage = "reopened"
      elseif stage == "reopened" and not p.closed and not p.loading and api.nvim_get_mode().mode == "i" then
        mark("move_final")
        stage = "final"
      elseif stage == "final" and p:current().seq == old_seq and delta() then
        mark("confirm")
        stage = "confirmed"
      elseif stage == "confirmed" and p.closed then
        assert(api.nvim_get_current_buf() == source and vim.fn.undotree().seq_cur == old_seq)
        assert(vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), old_lines))
        finish(
          true,
          "PASS "
            .. (configured and "configured " or "")
            .. "Space su: parent/current F4 comparison, branch graph, ancestor context, delta, zero matches, resizing, Escape/focus and confirmation"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
