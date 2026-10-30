vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile, vim.o.termguicolors = false, true
local tools = require("selection_tools")
local dir = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local function git(args)
  local cmd = { "git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-C", dir }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
git({ "init", "-q" })
git({ "config", "user.name", "Selection Test" })
git({ "config", "user.email", "selection@example.invalid" })
vim.fn.writefile({ "base" }, dir .. "/file.lua")
git({ "add", "--all" })
git({ "commit", "-qm", "history fixture" })
local head = git({ "rev-parse", "HEAD" })
vim.fn.writefile({ "added needle" }, dir .. "/file.lua")
local p = tools.git_diff({ cwd = dir, layout = { width = 0.95, height = 0.95, preview_height = 0.8 } })
local stage, ticks = "diff", 0
local timer = assert(vim.uv.new_timer())
local function mark(value)
  vim.fn.writefile({ value }, dir .. "/stage")
end
local function finish(ok, text)
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), dir .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 600, "Git terminal timeout at " .. stage)
      if stage == "diff" and not p.loading then
        local text = table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
        if not text:find("+added needle", 1, true) then
          return
        end
        vim.cmd.redraw()
        local ns = vim.api.nvim_get_namespaces().selection_tools_diff
        local colors = {}
        local top, left = unpack(vim.api.nvim_win_get_position(p.preview_win))
        local off = vim.fn.getwininfo(p.preview_win)[1].textoff
        local view = vim.api.nvim_win_call(p.preview_win, vim.fn.winsaveview)
        for _, span in ipairs(vim.api.nvim_buf_get_extmarks(p.preview_buf, ns, 0, -1, { details = true })) do
          colors[span[4].hl_group] = vim.fn.screenattr(top + span[2] - view.topline + 2, left + off + 1)
        end
        assert(colors.SelectionToolsDiffAdd and colors.SelectionToolsDiffDelete)
        assert(
          colors.SelectionToolsDiffAdd ~= colors.SelectionToolsDiffHeader
            and colors.SelectionToolsDiffAdd ~= colors.SelectionToolsDiffDelete,
          "Diff colors are not visible: " .. vim.inspect(colors)
        )
        assert(vim.api.nvim_get_current_win() == p.input_win)
        mark("cancel")
        stage = "log_open"
      elseif stage == "log_open" and p.closed then
        p = tools.git_log({ cwd = dir, layout = { width = 0.95, height = 0.95 } })
        stage = "log"
      elseif stage == "log" and not p.loading and vim.api.nvim_get_mode().mode == "i" then
        assert(#p.matches == 1)
        mark("git_query")
        stage = "queried"
      elseif stage == "queried" and p.query == "history" and #p.matches == 1 then
        local text = table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
        if not text:find("+base", 1, true) then
          return
        end
        mark("confirm")
        stage = "confirmed"
      elseif stage == "confirmed" and p.closed and vim.bo.filetype == "diff" and vim.bo.readonly then
        if not table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find("+base", 1, true) then
          return
        end
        assert(git({ "rev-parse", "HEAD" }) == head)
        finish(
          true,
          "PASS terminal Git: visible added/deleted/header diff colors, commit query, read-only confirmation and unchanged HEAD"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
