vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local runtime = directory .. "/runtime"
vim.fn.mkdir(runtime .. "/doc", "p")
local tags = { "beta\tselection-lazy.txt\t/*beta*", "zbeta\tselection-lazy.txt\t/*zbeta*" }
for i = 1, 5000 do
  tags[#tags + 1] = ("entry_%05d\tselection-lazy.txt\t/*entry_%05d*"):format(i, i)
end
vim.fn.writefile(tags, runtime .. "/doc/tags")
vim.fn.writefile({ "Test help", "*beta* First result", "*zbeta* Second result" }, runtime .. "/doc/selection-lazy.txt")
vim.opt.runtimepath:prepend(runtime)
local get_runtime = vim.api.nvim_get_runtime_file
vim.api.nvim_get_runtime_file = function(pattern, all)
  if pattern == "doc/tags" then
    return { runtime .. "/doc/tags" }
  end
  return get_runtime(pattern, all)
end
local read, close = vim.uv.fs_read, vim.uv.fs_close
local reading, reads, closes = false, 0, 0
vim.uv.fs_read = function(fd, size, offset, callback)
  reading, reads = true, reads + 1
  return read(fd, size, offset, function(err, data)
    vim.defer_fn(function()
      callback(err, data)
    end, 120)
  end)
end
vim.uv.fs_close = function(...)
  closes = closes + 1
  return close(...)
end
local p = tools.help({ preview = { enabled = false } })
assert(p.loading and #p.entries == 0)
vim.cmd.redraw()
local row, col = unpack(vim.api.nvim_win_get_position(p.list_win))
local screen = {}
for c = col + 1, col + 30 do
  screen[#screen + 1] = vim.fn.screenstring(row + 1, c)
end
assert(table.concat(screen):find("Loading", 1, true), "Loading frame was not drawn before I/O")
local timer = assert(vim.uv.new_timer())
local stage, ticks, heartbeats, cached_reads, finished = "loading", 0, 0, nil, false
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function finish(ok, message)
  finished = true
  timer:stop()
  timer:close()
  vim.uv.fs_read, vim.uv.fs_close = read, close
  vim.api.nvim_get_runtime_file = get_runtime
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  5,
  5,
  vim.schedule_wrap(function()
    if finished then
      return
    end
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 1500, "Lazy terminal timeout at " .. stage)
      if not p.closed and p.loading then
        heartbeats = heartbeats + 1
      end
      local insert = vim.api.nvim_get_mode().mode == "i"
      if stage == "loading" and reading and insert then
        mark("type")
        stage = "typed"
      elseif stage == "typed" and p.query == "bta" then
        assert(p.loading and insert and vim.api.nvim_get_current_win() == p.input_win)
        mark("cancel")
        stage = "cancelled"
      elseif stage == "cancelled" and p.closed and closes > 0 then
        vim.uv.fs_read = function(...)
          reads = reads + 1
          return read(...)
        end
        p = tools.help({ preview = { enabled = false } })
        mark("type_again")
        stage = "second"
      elseif stage == "second" and p.query == "bta" and not p.loading and insert then
        assert(#p.matches == 2 and p:current().tag == "beta")
        assert(heartbeats >= 3, "Loading prevented event-loop heartbeats")
        cached_reads = reads
        mark("confirm")
        stage = "chosen"
      elseif stage == "chosen" and p.closed then
        assert(vim.bo.buftype == "help" and vim.api.nvim_win_get_cursor(0)[1] == 2)
        p = tools.help({ query = "bta", preview = { enabled = false } })
        stage = "cached"
      elseif stage == "cached" and not p.loading and insert then
        assert(reads == cached_reads and #p.matches == 2)
        mark("close_warm")
        stage = "closed"
      elseif stage == "closed" and p.closed then
        finish(
          true,
          "PASS terminal lazy loading: visible frame before I/O; typing and Escape during reads; cancelled descriptor cleanup; batched 5,002 tags; native help confirmation; cached reopen without file reads"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
