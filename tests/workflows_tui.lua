local configured = vim.env.SELECTION_TOOLS_CONFIGURED == "1"
if not configured then
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
end
vim.o.swapfile = false
local tools = require("selection_tools")
assert(
  debug.getinfo(require("selection_tools.picker").new, "S").source
    == "@" .. vim.fn.getcwd() .. "/lua/selection_tools/picker.lua"
)
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
vim.fn.mkdir(directory .. "/sub", "p")
vim.fn.writefile({ "needle[1]" }, directory .. "/root.lua")
vim.fn.writefile({ "needle[1]" }, directory .. "/sub/child.lua")
local p = tools.grep({ cwd = directory, query = "needle[1]", debounce_ms = 0 })
local stage, ticks = "start", 0
local origin = p.origin_win
local timer = assert(vim.uv.new_timer())
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function finish(ok, text)
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
local function check_borders()
  vim.cmd.redraw()
  local api = vim.api
  local frame = p.resolved.frame
  local lines = api.nvim_buf_get_lines(p.separator_buf, 0, -1, false)
  assert(api.nvim_win_get_config(p.frame_win).title[1][1] == " " .. p.opts.prompt .. " ")
  local path_index = p.opts.layout.input_position == "bottom" and 1 or #lines
  local filter_index = p.opts.layout.input_position == "bottom" and #lines or 1
  local expected = vim.fn.fnamemodify(p.opts.cwd, ":~")
  local label = lines[path_index]
  if not label:find(expected, 1, true) then
    local visible = label:match(" (.-)…")
    assert(visible and #visible > 0 and expected:sub(1, #visible) == visible, "Invalid clipped directory label")
  end
  assert(lines[filter_index]:find(p.opts.hidden and "hidden:on" or "hidden:off", 1, true))
  assert(lines[filter_index]:find(p.opts.ignored and "ignore:off" or "ignore:on", 1, true))
  if p.opts.source == "grep" then
    assert(lines[filter_index]:find(p.opts.regex and "regex" or "literal", 1, true))
  end
  for i, row in ipairs(p.resolved.separators) do
    local screen = {}
    for col = frame.col + 1, frame.col + p.resolved.width + 2 do
      screen[#screen + 1] = vim.fn.screenstring(frame.row + row + 2, col)
    end
    assert(table.concat(screen) == lines[i], "Divider label is not displayed at its own row")
  end
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 600, "Workflow timeout at " .. stage)
      if stage == "start" and not p.loading and vim.api.nvim_get_mode().mode == "i" then
        assert(#p.matches == 2)
        check_borders()
        mark("hidden")
        stage = "hidden"
      elseif stage == "hidden" and p.opts.hidden and not p.loading then
        check_borders()
        mark("ignored")
        stage = "ignored"
      elseif stage == "ignored" and p.opts.ignored and not p.loading then
        check_borders()
        mark("regex")
        stage = "regex"
      elseif stage == "regex" and p.opts.regex and not p.loading then
        assert(#p.matches == 0)
        check_borders()
        mark("literal")
        stage = "literal"
      elseif stage == "literal" and p.opts.regex == false and not p.loading then
        assert(#p.matches == 2)
        check_borders()
        mark("scope")
        stage = "scope"
      elseif stage == "scope" and p.prompting then
        mark("scope_value")
        stage = "scoped"
      elseif stage == "scoped" and p.opts.cwd == directory .. "/sub" and not p.loading then
        assert(not p.closed and #p.matches == 1 and p.query == "needle[1]")
        assert(vim.api.nvim_get_current_win() == p.input_win)
        check_borders()
        mark("export")
        stage = "exported"
      elseif stage == "exported" and p.closed then
        local qf = vim.fn.getqflist()
        assert(#qf == 1 and qf[1].lnum == 1 and qf[1].col == 1)
        vim.cmd.cclose()
        vim.api.nvim_set_current_win(origin)
        if configured then
          vim.cmd.cd(directory .. "/sub")
          local files = tools.files
          tools.files = function(opts)
            p = files(opts)
            tools.files = files
            return p
          end
          assert(vim.fn.maparg(" sf", "n") ~= "", "Space sf is not mapped")
          mark("open_files")
        else
          p = tools.files({ cwd = directory .. "/sub" })
        end
        stage = "split_ready"
      elseif stage == "split_ready" and not p.closed and not p.loading and vim.api.nvim_get_mode().mode == "i" then
        check_borders()
        mark("expand")
        stage = "expanded"
      elseif stage == "expanded" and p.normal_preview_height then
        assert(vim.api.nvim_get_current_win() == p.input_win)
        check_borders()
        mark("collapse")
        stage = "collapsed"
      elseif stage == "collapsed" and not p.normal_preview_height then
        check_borders()
        mark("details")
        stage = "details"
      elseif stage == "details" and p.detail_win and vim.api.nvim_get_mode().mode == "n" then
        assert(not p.closed and vim.api.nvim_get_current_win() == p.detail_win)
        mark("details_close")
        stage = "details_closed"
      elseif stage == "details_closed" and not p.detail_win and vim.api.nvim_get_mode().mode == "i" then
        assert(vim.api.nvim_get_current_win() == p.input_win)
        mark("split")
        stage = "split_done"
      elseif stage == "split_done" and p.closed then
        assert(vim.api.nvim_get_current_win() ~= origin)
        assert(vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "child.lua")
        finish(
          true,
          "PASS "
            .. (configured and "configured Space sf " or "")
            .. "terminal workflow: border title/path/filters, hidden/ignore toggles, search mode/scope prompts, exact Quickfix exports, full item details return to picker, vertical split key opens selected file"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
