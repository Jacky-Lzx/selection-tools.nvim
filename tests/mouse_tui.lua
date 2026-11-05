vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
vim.o.mouse = "a"
local api = vim.api
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)

local function run()
  local function wait(test, message)
    local started = vim.uv.hrtime()
    while not test() do
      assert(
        (vim.uv.hrtime() - started) / 1e6 < 3000,
        message
          .. ": "
          .. vim.inspect({ mouse = vim.fn.getmousepos(), win = api.nvim_get_current_win(), mode = vim.fn.mode() })
      )
      coroutine.yield()
    end
  end
  vim.cmd("enew!")
  local origin = api.nvim_get_current_win()
  local origin_buf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "origin buffer text", "second line", "mouse target text" })
  vim.cmd("vnew")
  local split = api.nvim_get_current_win()
  local split_buf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(split_buf, 0, -1, false, { "other buffer text", "second line", "mouse target text" })
  api.nvim_set_current_win(origin)

  for index, destination in ipairs({ origin, split }) do
    local calls = 0
    local p = tools.select({ "beta", "gamma" }, {
      layout = { width = 0.6, height = 0.5, min_width = 1 },
    }, function(item, item_index)
      assert(item == nil and item_index == nil, "outside click cancels selection")
      calls = calls + 1
    end)
    wait(function()
      return api.nvim_get_current_win() == p.input_win and vim.fn.mode() == "i"
    end, "picker must accept Insert-mode input before the mouse click")

    vim.cmd.redraw()
    local position = vim.fn.screenpos(destination, 3, 8)
    local row, col = position.row, position.col
    local frame = p.resolved.frame
    assert(row > 0 and col > 0 and row <= frame.row, "mouse target must be outside the picker")
    vim.fn.writefile({ (col + 4) .. " " .. row }, directory .. "/mouse")
    vim.fn.writefile({ "click_" .. index }, directory .. "/stage")
    wait(function()
      return p.closed and vim.fn.mode() == "n"
    end, "outside mouse click closes the picker in Normal mode")
    assert(vim.fn.mode() == "n", "outside mouse click must leave Normal mode, got " .. vim.fn.mode())
    assert(api.nvim_get_current_win() == destination, "closing must keep the clicked window focused")
    assert(calls == 1, "outside click must cancel exactly once")
    assert(not api.nvim_win_is_valid(p.input_win) and not api.nvim_win_is_valid(p.list_win))
    assert(api.nvim_buf_get_lines(origin_buf, 0, -1, false)[1] == "origin buffer text")
    assert(api.nvim_buf_get_lines(split_buf, 0, -1, false)[1] == "other buffer text")
  end
end

local thread = coroutine.create(run)
local function step()
  local ok, err = coroutine.resume(thread)
  if not ok then
    vim.fn.writefile({ tostring(err), debug.traceback(thread) }, directory .. "/result")
    vim.cmd("cquit 1")
  elseif coroutine.status(thread) == "dead" then
    vim.fn.writefile(
      { "PASS terminal mouse cancellation: origin and other split stay in Normal mode" },
      directory .. "/result"
    )
    vim.cmd("qa!")
  else
    vim.defer_fn(step, 10)
  end
end
vim.defer_fn(step, 30)
