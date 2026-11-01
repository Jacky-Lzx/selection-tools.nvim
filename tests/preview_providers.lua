vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local passed, failed = 0, 0
vim.notify = function() end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function test(name, fn)
  local windows = vim.api.nvim_list_wins()
  local ok, err = xpcall(fn, debug.traceback)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not vim.tbl_contains(windows, win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.wait(10, function()
    return false
  end, 1)
  tools.setup()
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end
local function ready(p)
  assert(
    vim.wait(5000, function()
      return not p.loading and not p.matching and not p.syntax_pending
    end, 2),
    "source timed out"
  )
  assert(not p.error, p.error)
end
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local text = fixture .. "/text.txt"
local png = fixture .. "/figure.PNG"
vim.fn.writefile({ "plain text" }, text)
vim.fn.writefile({ "fake png fixture" }, png)
local function open(providers, extra)
  local opts = vim.tbl_deep_extend("force", {
    items = { { file = png }, { file = text } },
    format_item = function(item)
      return item.file
    end,
    preview = { enabled = true, providers = providers },
  }, extra or {})
  return tools.open(opts)
end
local function wait_text(p)
  assert(vim.wait(2000, function()
    return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "plain text"
  end, 2))
end
test("provider chains paint atomic lines/extmarks and receive resize and close", function()
  local ctx, closed, resized = nil, 0, 0
  local ns = vim.api.nvim_create_namespace("provider_test")
  local p = open({
    function()
      return false
    end,
    function(value)
      if value.path ~= png then
        return false
      end
      ctx = value
      assert(ctx.paint(function(buf, win)
        assert(win == ctx.win and vim.bo[buf].modifiable)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "grid" })
        vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 4, hl_group = "Search" })
      end))
      return {
        close = function()
          closed = closed + 1
        end,
        resize = function()
          resized = resized + 1
        end,
      }
    end,
  })
  assert(ctx and not vim.bo[p.preview_buf].modifiable)
  eq(#vim.api.nvim_buf_get_extmarks(p.preview_buf, ns, 0, -1, {}), 1)
  p:expand_preview()
  eq(resized, 1)
  p:move(1)
  wait_text(p)
  eq(closed, 1)
  assert(not ctx.paint(function()
    error("stale paint executed")
  end))
  ctx.set_lines({ "stale" })
  vim.wait(20, function()
    return false
  end, 1)
  eq(vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1], "plain text")
  p:close()
  eq(closed, 1)
end)
test("legacy previewers retain precedence and may return view handles", function()
  local calls, closed = 0, 0
  local p = open({
    function()
      error("must not run")
    end,
  }, {
    previewer = function(ctx)
      calls = calls + 1
      ctx.set_lines({ "legacy" })
      return {
        close = function()
          closed = closed + 1
        end,
      }
    end,
  })
  assert(vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "legacy"
  end, 1))
  p:close()
  eq(calls, 1)
  eq(closed, 1)
end)
test("paint schedules safely from fast callbacks and rejects cancelled work", function()
  local ctx, painted, fast = nil, 0, nil
  local p = open({
    function(value)
      ctx = value
      return true
    end,
  })
  local timer = vim.uv.new_timer()
  timer:start(1, 0, function()
    ctx.paint(function(buf)
      painted = painted + 1
      fast = vim.in_fast_event()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fast callback grid" })
    end)
    timer:close()
  end)
  assert(vim.wait(1000, function()
    return painted == 1
  end, 1))
  assert(not fast)
  p:close()
  assert(not ctx.paint(function()
    painted = painted + 1
  end))
  eq(painted, 1)
end)
test("image-tools adapter stays lazy and delegates only supported image candidates", function()
  local loaded, preload = package.loaded.image_tools, package.preload.image_tools
  local loads, requests, closed, resized = 0, {}, 0, 0
  package.loaded.image_tools = nil
  package.preload.image_tools = function()
    loads = loads + 1
    return {
      supports = function(path)
        return path == png
      end,
      render = function(request)
        requests[#requests + 1] = request
        request.paint(function()
          vim.api.nvim_buf_set_lines(request.buf, 0, -1, false, { "native grid" })
        end)
        return {
          close = function()
            closed = closed + 1
          end,
          resize = function()
            resized = resized + 1
          end,
        }
      end,
    }
  end
  local ok, err = pcall(function()
    local provider = require("selection_tools.integrations.image_tools").provider()
    local p = open({ provider }, { items = { { file = text }, { file = png } } })
    wait_text(p)
    eq(loads, 0)
    p:move(1)
    eq(loads, 1)
    eq(#requests, 1)
    eq(requests[1].buf, p.preview_buf)
    eq(requests[1].win, p.preview_win)
    eq(vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1], "native grid")
    p:expand_preview()
    eq(resized, 1)
    p:move(1)
    wait_text(p)
    eq(closed, 1)
    requests[1].on_error("late failure")
    vim.wait(20, function()
      return false
    end, 1)
    eq(vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1], "plain text")
    p:close()
  end)
  package.loaded.image_tools, package.preload.image_tools = loaded, preload
  assert(ok, err)
end)
test("modified image-named buffers retain their unsaved text without loading a renderer", function()
  local buf = vim.fn.bufadd(png)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved image source" })
  local loaded = package.loaded.image_tools
  local p = open({ require("selection_tools.integrations.image_tools").provider() })
  assert(vim.wait(1000, function()
    return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "unsaved image source"
  end, 1))
  eq(package.loaded.image_tools, loaded)
  assert(vim.bo[buf].modified)
  p:close()
  vim.bo[buf].modified = false
  vim.api.nvim_buf_delete(buf, { force = true })
end)
test("a paint callback may close its owner without touching dead panes", function()
  local ctx
  local p = open({
    function(value)
      ctx = value
      return true
    end,
  })
  assert(not ctx.paint(function()
    p:close()
  end))
  assert(p.closed)
end)
test("retained provider frames remain until the next guarded paint or cancellation", function()
  local pending, old, closed
  closed = 0
  local retained = {
    close = function()
      closed = closed + 1
    end,
  }
  retained.retain = function(self)
    return self
  end
  local p = open({
    function(ctx)
      if ctx.path == png then
        old = ctx
        ctx.paint(function(buf)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "retained grid" })
        end)
        return retained
      end
      pending = ctx
      return true
    end,
  })
  p:move(1)
  eq(closed, 0)
  eq(pending.previous, retained)
  assert(pending.has_preview)
  eq(vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1], "retained grid")
  assert(not old.paint(function()
    error("stale frame repainted")
  end))
  pending.paint(function(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ready replacement" })
  end)
  eq(closed, 1)
  eq(vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1], "ready replacement")
  p:close()
  eq(closed, 1)
  closed = 0
  p = open({
    function(ctx)
      if ctx.path == png then
        ctx.paint(function(buf)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "retained grid" })
        end)
        return retained
      end
      return true
    end,
  })
  p:move(1)
  eq(closed, 0)
  p:set_query("no such entry")
  eq(closed, 1)
  p:close()
  eq(closed, 1)
end)
vim.fn.delete(fixture, "rf")
print(("%d preview provider tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
