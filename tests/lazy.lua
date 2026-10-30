vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local passed, failed = 0, 0
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
      return not p.loading and not p.matching
    end, 1),
    "source timed out"
  )
  assert(not p.error, p.error)
end
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")

test("setup installs the selection adapter without loading picker or source implementations", function()
  tools.setup({ ui_select = true })
  assert(type(vim.ui.select) == "function")
  for name in pairs(package.loaded) do
    assert(not name:match("^selection_tools%.sources%."), name)
  end
  assert(not package.loaded["selection_tools.picker"] and not package.loaded["selection_tools.preview"])
  assert(not package.loaded["selection_tools.matcher"])
end)

test("highlight attributes are read only for the previewed item and reflect current colors", function()
  local get_hl, calls = vim.api.nvim_get_hl, {}
  vim.api.nvim_set_hl(0, "SelectionLazyHighlight", { fg = "#123456" })
  vim.api.nvim_get_hl = function(ns, opts)
    calls[#calls + 1] = opts.name
    return get_hl(ns, opts)
  end
  local ok, err = xpcall(function()
    local spec = require("selection_tools.sources.highlights")({})
    eq(#calls, 0)
    vim.api.nvim_set_hl(0, "SelectionLazyHighlight", { fg = "#654321" })
    local p = tools.open(vim.tbl_extend("force", spec, { query = "SelectionLazyHighlight" }))
    ready(p)
    assert(vim.wait(1000, function()
      return table
        .concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
        :find(tostring(0x654321), 1, true)
    end, 1))
    eq(calls, { "SelectionLazyHighlight", "SelectionLazyHighlight" })
    p:close()
  end, debug.traceback)
  vim.api.nvim_get_hl = get_hl
  assert(ok, err)
end)

test("keymap definitions are resolved only for preview or explicit definition navigation", function()
  local util = require("selection_tools.sources.util")
  local original, calls = util.definition, 0
  util.definition = function(...)
    calls = calls + 1
    return original(...)
  end
  vim.keymap.set("n", "<F7>", "<Nop>", { desc = "selection_lazy_mapping" })
  local buf = vim.api.nvim_get_current_buf()
  local ok, err = xpcall(function()
    local p = tools.keymaps({ modes = { "n" }, query = "selection_lazy_mapping", preview = { enabled = false } })
    ready(p)
    eq(calls, 0)
    p:confirm()
    vim.api.nvim_feedkeys("", "x", false)
    eq(calls, 0)
    p = tools.keymaps({
      modes = { "n" },
      query = "selection_lazy_mapping",
      preview = { enabled = false },
      action = "definition",
    })
    ready(p)
    eq(calls, 0)
    p:confirm()
    eq(calls, 1)
  end, debug.traceback)
  util.definition = original
  vim.keymap.del("n", "<F7>")
  vim.api.nvim_set_current_buf(buf)
  assert(ok, err)
end)

test("script indexes are reused within a picker and refreshed for a new picker", function()
  local getscriptinfo, calls = vim.fn.getscriptinfo, 0
  vim.fn.getscriptinfo = function()
    calls = calls + 1
    return { { sid = 100, name = fixture .. "/first.vim" }, { sid = 200, name = fixture .. "/second.vim" } }
  end
  local ok, err = xpcall(function()
    local definitions = require("selection_tools.sources.util").definitions
    local resolve = definitions()
    eq(calls, 0)
    eq(resolve(nil, 100, 3).pos, { 3, 0 })
    eq(resolve(nil, 200, 7).file, fixture .. "/second.vim")
    eq(calls, 1)
    eq(definitions()(nil, 100, 1).file, fixture .. "/first.vim")
    eq(calls, 2)
  end, debug.traceback)
  vim.fn.getscriptinfo = getscriptinfo
  assert(ok, err)
end)

test("candidate preparation yields to the event loop and stops on cancellation or failure", function()
  local count, delivered, failed = 0, false, nil
  local cancel = require("selection_tools.sources.util").collect({
    is_cancelled = function()
      return false
    end,
    set_items = function()
      delivered = true
    end,
    done = function() end,
    fail = function(err)
      failed = err
    end,
  }, function(checkpoint)
    for _ = 1, 10000 do
      count = count + 1
      checkpoint()
    end
    return {}
  end)
  eq(count, 0)
  assert(vim.wait(1000, function()
    return count > 0
  end, 1))
  assert(count < 10000)
  cancel()
  local stopped = count
  vim.wait(20, function()
    return false
  end, 1)
  eq(count, stopped)
  assert(not delivered and not failed)
  require("selection_tools.sources.util").collect({
    is_cancelled = function()
      return false
    end,
    fail = function(err)
      failed = err
    end,
  }, function()
    error("preparation failed")
  end)
  assert(vim.wait(1000, function()
    return failed ~= nil
  end, 1))
  assert(tostring(failed):find("preparation failed", 1, true))
end)

test("help indexes reuse reads and invalidate changed files, runtime order and deletion", function()
  local runtime, read = vim.api.nvim_get_runtime_file, vim.uv.fs_read
  local reads, paths = 0, {}
  local first, second = fixture .. "/one/tags", fixture .. "/two/tags"
  vim.fn.mkdir(fixture .. "/one", "p")
  vim.fn.mkdir(fixture .. "/two", "p")
  vim.fn.writefile({ "shared_tag\tone.txt\t/*shared_tag*", "first_only\tone.txt\t/*first_only*" }, first)
  vim.fn.writefile({ "shared_tag\ttwo.txt\t/*shared_tag*" }, second)
  paths = { first, second }
  vim.api.nvim_get_runtime_file = function(pattern, all)
    if pattern == "doc/tags" then
      return paths
    end
    return runtime(pattern, all)
  end
  vim.uv.fs_read = function(...)
    reads = reads + 1
    return read(...)
  end
  local function open(query)
    local p = tools.help({ query = query, preview = { enabled = false } })
    assert(p.loading and #p.entries == 0)
    ready(p)
    return p
  end
  local ok, err = xpcall(function()
    local p = open("shared_tag")
    eq(#p.matches, 1)
    eq(p:current().file, fixture .. "/one/one.txt")
    p:current().tag = "modified_by_caller"
    p:close()
    local initial = reads
    p = open("shared_tag")
    eq(reads, initial)
    eq(p:current().tag, "shared_tag")
    p:close()
    paths = { second, first }
    p = open("shared_tag")
    eq(reads, initial)
    eq(p:current().file, fixture .. "/two/two.txt")
    p:close()
    vim.fn.writefile({ "changed_tag_longer\tchanged.txt\t/*changed_tag_longer*" }, second)
    p = open("changed_tag_longer")
    eq(#p.matches, 1)
    assert(reads > initial)
    p:close()
    vim.fn.delete(second)
    p = open("changed_tag_longer")
    eq(#p.matches, 0)
    p:close()
    paths = {}
    p = open("first_only")
    eq(#p.matches, 0)
    p:close()
  end, debug.traceback)
  vim.api.nvim_get_runtime_file, vim.uv.fs_read = runtime, read
  assert(ok, err)
end)

test("cancelled help reads release descriptors and cannot replace a later picker", function()
  local runtime, read, close = vim.api.nvim_get_runtime_file, vim.uv.fs_read, vim.uv.fs_close
  local path, reading, closes = fixture .. "/cancel-tags", false, 0
  vim.fn.writefile({ "cancelled_help_tag\told.txt\t/*cancelled_help_tag*" }, path)
  vim.api.nvim_get_runtime_file = function(pattern, all)
    if pattern == "doc/tags" then
      return { path }
    end
    return runtime(pattern, all)
  end
  vim.uv.fs_read = function(fd, size, offset, callback)
    reading = true
    return read(fd, size, offset, function(err, data)
      vim.defer_fn(function()
        callback(err, data)
      end, 30)
    end)
  end
  vim.uv.fs_close = function(...)
    closes = closes + 1
    return close(...)
  end
  local ok, err = xpcall(function()
    local p = tools.help({ preview = { enabled = false } })
    assert(vim.wait(1000, function()
      return reading
    end, 1))
    p:close()
    local next_picker = tools.select({ "new choice" }, {}, function() end)
    assert(vim.wait(1000, function()
      return closes > 0
    end, 1))
    eq(next_picker:current(), "new choice")
    assert(p.closed and not next_picker.closed)
    next_picker:close()
  end, debug.traceback)
  vim.api.nvim_get_runtime_file, vim.uv.fs_read, vim.uv.fs_close = runtime, read, close
  assert(ok, err)
end)

test("static sources mount before enumeration and immediate cancellation skips preparation", function()
  local originals = {
    completion = vim.fn.getcompletion,
    runtime = vim.api.nvim_get_runtime_file,
    maps = vim.api.nvim_get_keymap,
    autocmds = vim.api.nvim_get_autocmds,
    root = vim.fs.root,
  }
  local calls = 0
  local function count(fn)
    return function(...)
      calls = calls + 1
      return fn(...)
    end
  end
  vim.fn.getcompletion = count(originals.completion)
  vim.api.nvim_get_runtime_file = count(originals.runtime)
  vim.api.nvim_get_keymap = count(originals.maps)
  vim.api.nvim_get_autocmds = count(originals.autocmds)
  vim.fs.root = count(originals.root)
  local ok, err = xpcall(function()
    for _, name in ipairs({ "help", "highlights", "keymaps", "autocmds", "commands", "projects" }) do
      local before = calls
      local p = tools.pick(name, { preview = { enabled = false } })
      assert(vim.api.nvim_win_is_valid(p.input_win) and p.loading and #p.entries == 0, name)
      eq(calls, before)
      p:close()
      vim.wait(10, function()
        return false
      end, 1)
      eq(calls, before)
    end
  end, debug.traceback)
  vim.fn.getcompletion, vim.api.nvim_get_runtime_file = originals.completion, originals.runtime
  vim.api.nvim_get_keymap, vim.api.nvim_get_autocmds, vim.fs.root = originals.maps, originals.autocmds, originals.root
  assert(ok, err)
end)

test("project discovery caches negative roots within one scan", function()
  local root, oldfiles = vim.fs.root, vim.v.oldfiles
  local directory = fixture .. "/no-project"
  vim.fn.mkdir(directory, "p")
  local calls = 0
  vim.fs.root = function(path, markers)
    if path == directory then
      calls = calls + 1
      return nil
    end
    return root(path, markers)
  end
  vim.v.oldfiles = { directory .. "/one.txt", directory .. "/two.txt" }
  local ok, err = xpcall(function()
    local p = tools.projects({ dev = {}, preview = { enabled = false } })
    ready(p)
    eq(calls, 1)
    p:close()
  end, debug.traceback)
  vim.fs.root, vim.v.oldfiles = root, oldfiles
  assert(ok, err)
end)

vim.fn.delete(fixture, "rf")
print(("%d lazy-loading tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
