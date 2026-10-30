vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local tools = require("selection_tools")
local dir = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local svg =
  '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="40" height="40" fill="red"/><rect x="40" width="40" height="40" fill="blue"/></svg>'
vim.fn.writefile({ svg }, dir .. "/plot.svg")
local p = tools.files({ cwd = dir, query = "plot", preview = { image = { backend = "chafa" } } })
local timer, ticks, checked = assert(vim.uv.new_timer()), 0, false
local function finish(ok, message)
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), dir .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 500, "Image terminal timeout")
      if checked and p.closed then
        assert(not vim.api.nvim_buf_is_valid(p.preview_buf))
        finish(true, "PASS terminal colored SVG preview: two visible screen colors, fits pane, input focus and cleanup")
        return
      end
      local ns = vim.api.nvim_get_namespaces().selection_tools_image
      if checked or not ns or p.loading or vim.api.nvim_get_mode().mode ~= "i" then
        return
      end
      local marks = vim.api.nvim_buf_get_extmarks(p.preview_buf, ns, 0, -1, { details = true })
      if #marks < 2 then
        return
      end
      vim.cmd.redraw()
      local attrs = {}
      local top, left = unpack(vim.api.nvim_win_get_position(p.preview_win))
      for _, mark in ipairs(marks) do
        local line = vim.api.nvim_buf_get_lines(p.preview_buf, mark[2], mark[2] + 1, false)[1]
        assert(vim.fn.strwidth(line) <= vim.api.nvim_win_get_width(p.preview_win))
        local cell = left + vim.fn.strwidth(line:sub(1, mark[3])) + 1
        attrs[vim.fn.screenattr(top + mark[2] + 1, cell)] = true
      end
      assert(vim.tbl_count(attrs) >= 2, "Image colors did not reach the terminal screen")
      assert(vim.api.nvim_get_current_win() == p.input_win and not vim.wo[p.preview_win].number)
      checked = true
      vim.fn.writefile({ "cancel" }, dir .. "/stage")
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
