vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
vim.fn.mkdir(directory .. "/sub", "p")
vim.fn.writefile({ "needle[1]" }, directory .. "/root.lua")
vim.fn.writefile({ "needle[1]" }, directory .. "/sub/child.lua")
local p = tools.grep({ cwd = directory, query = "needle[1]", debounce_ms = 0 })
local stage, ticks = "start", 0
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
        finish(
          true,
          "PASS terminal search controls: literal/regex toggle, directory prompt keeps picker alive and input intact, scoped results export to Quickfix"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
