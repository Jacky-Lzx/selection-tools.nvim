vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
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
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 600, "Workflow timeout at " .. stage)
      if stage == "start" and not p.loading and vim.api.nvim_get_mode().mode == "i" then
        assert(#p.matches == 2)
        mark("regex")
        stage = "regex"
      elseif stage == "regex" and p.opts.regex and not p.loading then
        assert(#p.matches == 0)
        mark("literal")
        stage = "literal"
      elseif stage == "literal" and p.opts.regex == false and not p.loading then
        assert(#p.matches == 2)
        mark("scope")
        stage = "scope"
      elseif stage == "scope" and p.prompting then
        mark("scope_value")
        stage = "scoped"
      elseif stage == "scoped" and p.opts.cwd == directory .. "/sub" and not p.loading then
        assert(not p.closed and #p.matches == 1 and p.query == "needle[1]")
        assert(vim.api.nvim_get_current_win() == p.input_win)
        mark("export")
        stage = "exported"
      elseif stage == "exported" and p.closed then
        local qf = vim.fn.getqflist()
        assert(#qf == 1 and qf[1].lnum == 1 and qf[1].col == 1)
        vim.cmd.cclose()
        vim.api.nvim_set_current_win(origin)
        p = tools.files({ cwd = directory .. "/sub" })
        stage = "split_ready"
      elseif stage == "split_ready" and not p.loading and vim.api.nvim_get_mode().mode == "i" then
        mark("expand")
        stage = "expanded"
      elseif stage == "expanded" and p.normal_preview_height then
        assert(vim.api.nvim_get_current_win() == p.input_win)
        mark("collapse")
        stage = "collapsed"
      elseif stage == "collapsed" and not p.normal_preview_height then
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
          "PASS terminal workflow: search mode/scope prompts, exact Quickfix exports, full item details return to picker, vertical split key opens selected file"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
