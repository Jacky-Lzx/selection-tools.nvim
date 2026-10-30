vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local queries = vim.fn.stdpath("data") .. "/lazy/nvim-treesitter/runtime"
if vim.fn.isdirectory(queries) == 1 then
  vim.opt.runtimepath:append(queries)
end
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
local function ready(p, path)
  assert(
    vim.wait(5000, function()
      return not p.loading and p.syntax and p.syntax.files[path] and not p.syntax.pending[path]
    end, 1),
    "syntax timed out"
  )
  assert(not p.error, p.error)
end
local function captures(p)
  local ret = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
    local group = mark[4].hl_group
    if type(group) == "string" and group:sub(1, 1) == "@" then
      local line = vim.api.nvim_buf_get_lines(p.list_buf, mark[2], mark[2] + 1, false)[1]
      local item = p.matches[p.row_to_index[mark[2] + 1]].item
      ret[#ret + 1] = { hl = group, text = line:sub(mark[3] + 1, mark[4].end_col), row = item.pos[1], file = item.file }
    end
  end
  return ret
end
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local function source(name, lines)
  local dir = fixture .. "/" .. name
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/test.lua"
  vim.fn.writefile(lines, path)
  return dir, path
end

test("real Lua captures use complete multiline context without creating source buffers", function()
  local dir, path = source("context", { "local message = [[", 'print("needle")', "]]", 'local value = "needle"' })
  local origin = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(origin)
  local p = tools.grep({ cwd = dir, query = "needle", debounce_ms = 0, preview = { enabled = false } })
  ready(p, path)
  local string, keyword = false, false
  for _, capture in ipairs(captures(p)) do
    if capture.row == 2 and capture.text:find("print", 1, true) then
      eq(capture.hl, "@string.lua")
      string = true
    end
    if capture.row == 4 and capture.text == "local" then
      keyword = true
    end
  end
  assert(string and keyword, "missing context-aware string or keyword capture")
  eq(vim.fn.bufnr(path), -1)
  eq(vim.api.nvim_buf_get_changedtick(origin), tick)
  p:close()
end)

test("syntax reuses unchanged file snapshots and invalidates edited files on the next query", function()
  local dir, path = source("cache", { 'local value = "needle"' })
  local read, reads = vim.uv.fs_read, 0
  vim.uv.fs_read = function(...)
    reads = reads + 1
    return read(...)
  end
  local ok, err = xpcall(function()
    local p = tools.grep({ cwd = dir, query = "needle", debounce_ms = 0, preview = { enabled = false } })
    ready(p, path)
    assert(#captures(p) > 0)
    local first = reads
    p:set_query("value")
    ready(p, path)
    eq(reads, first)
    vim.fn.writefile({ 'local changed_value = "needle"' }, path)
    p:set_query("needle")
    ready(p, path)
    assert(reads > first and p.syntax.files[path].lines[1]:find("changed_value", 1, true))
    p:close()
  end, debug.traceback)
  vim.uv.fs_read = read
  assert(ok, err)
end)

test("dirty-buffer context is preferred and refreshed without changing source state", function()
  local dir, path = source("dirty", { "local message = [[", 'print("needle")', "]]" })
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "local message = nil" })
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "-- closing marker" })
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local p = tools.grep({ cwd = dir, query = "needle", debounce_ms = 0, preview = { enabled = false } })
  ready(p, path)
  local function print_capture()
    for _, capture in ipairs(captures(p)) do
      if capture.row == 2 and capture.text:find("print", 1, true) then
        return capture.hl
      end
    end
  end
  assert(print_capture() and print_capture() ~= "@string.lua")
  eq(vim.api.nvim_buf_get_changedtick(buf), tick)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "local message = [[" })
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "]]" })
  tick = vim.api.nvim_buf_get_changedtick(buf)
  p:_render()
  ready(p, path)
  eq(print_capture(), "@string.lua")
  eq(vim.api.nvim_buf_get_changedtick(buf), tick)
  p:close()
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("bounded document caches evict offscreen parsers and recolor revisited results", function()
  local dir = fixture .. "/evict"
  vim.fn.mkdir(dir, "p")
  for i = 1, 20 do
    vim.fn.writefile({ 'local value = "needle"' }, dir .. ("/file%02d.lua"):format(i))
  end
  local p = tools.grep({
    cwd = dir,
    query = "needle",
    debounce_ms = 0,
    preview = { enabled = false },
    syntax = { cache_size = 1 },
    layout = { height = 8 },
  })
  assert(vim.wait(3000, function()
    return not p.loading
  end, 1))
  local function visible()
    assert(
      vim.wait(5000, function()
        for _, index in pairs(p.row_to_index) do
          local path = p.matches[index].item.file
          if not p.syntax or p.syntax.pending[path] or not p.syntax.files[path] or not p.syntax.files[path].parser then
            return false
          end
        end
        return true
      end, 1),
      "visible files did not finish"
    )
  end
  visible()
  eq(vim.tbl_count(p.syntax.files), p.height)
  local first = p.syntax.files[p.matches[1].item.file]
  p.index = #p.matches
  p:_render()
  visible()
  assert(vim.tbl_count(p.syntax.files) <= p.height)
  assert(not first.parser, "offscreen parser was retained")
  p.index = 1
  p:_render()
  visible()
  assert(#captures(p) > 0)
  p:close()
end)

test("missing parsers and size limits preserve grep results and query highlights", function()
  local dir, path = source("limits", { 'local value = "needle"' })
  local function check(p)
    ready(p, path)
    eq(#p.matches, 1)
    eq(#captures(p), 0)
    local marks = vim.api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })
    assert(vim.tbl_contains(
      vim.tbl_map(function(mark)
        return mark[4].hl_group
      end, marks),
      "SelectionToolsMatch"
    ))
    p:close()
  end
  check(tools.grep({
    cwd = dir,
    query = "needle",
    debounce_ms = 0,
    preview = { enabled = false },
    syntax = { max_size = 4 },
  }))
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local get_lines, reads = vim.api.nvim_buf_get_lines, 0
  vim.api.nvim_buf_get_lines = function(target, ...)
    if target == buf then
      reads = reads + 1
    end
    return get_lines(target, ...)
  end
  local bounded, bounded_err = xpcall(function()
    local p = tools.grep({
      cwd = dir,
      query = "needle",
      debounce_ms = 0,
      preview = { enabled = false },
      syntax = { max_size = 4 },
    })
    check(p)
    eq(reads, 0)
  end, debug.traceback)
  vim.api.nvim_buf_get_lines = get_lines
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(bounded, bounded_err)
  local parse = vim.treesitter.get_string_parser
  vim.treesitter.get_string_parser = function()
    error("missing parser")
  end
  local ok, err = xpcall(function()
    check(tools.grep({ cwd = dir, query = "needle", debounce_ms = 0, preview = { enabled = false } }))
    local p = tools.grep({
      cwd = dir,
      query = "needle",
      debounce_ms = 0,
      preview = { enabled = false },
      syntax = {
        enabled = false,
      },
    })
    assert(vim.wait(3000, function()
      return not p.loading
    end, 1))
    assert(not p.syntax)
    p:close()
  end, debug.traceback)
  vim.treesitter.get_string_parser = parse
  assert(ok, err)
end)

test("cancelled source reads release descriptors and cannot repaint another picker", function()
  local dir = source("cancel", { 'local value = "needle"' })
  local read, close = vim.uv.fs_read, vim.uv.fs_close
  local reading, closed = false, false
  vim.uv.fs_read = function(fd, size, offset, callback)
    reading = true
    return read(fd, size, offset, function(err, data)
      vim.defer_fn(function()
        callback(err, data)
      end, 30)
    end)
  end
  vim.uv.fs_close = function(...)
    closed = true
    return close(...)
  end
  local ok, err = xpcall(function()
    local p = tools.grep({ cwd = dir, query = "needle", debounce_ms = 0, preview = { enabled = false } })
    assert(vim.wait(3000, function()
      return reading
    end, 1))
    p:close()
    local next = tools.select({ "new picker" }, {}, function() end)
    assert(vim.wait(3000, function()
      return closed
    end, 1))
    eq(next:current(), "new picker")
    assert(not next.closed)
    next:close()
  end, debug.traceback)
  vim.uv.fs_read, vim.uv.fs_close = read, close
  assert(ok, err)
end)

for _, lang in ipairs({ "python", "rust", "html" }) do
  if pcall(vim.treesitter.language.add, lang) and vim.treesitter.query.get(lang, "highlights") then
    test("installed " .. lang .. " parser uses language-specific captures and injections", function()
      local snippets = {
        python = { "test.py", { "def needle():", '    return "needle"' } },
        rust = { "test.rs", { 'fn needle() { let text = "needle"; }' } },
        html = { "test.html", { '<script>const needle = "needle";</script>' } },
      }
      local dir = fixture .. "/" .. lang
      vim.fn.mkdir(dir, "p")
      local snippet = snippets[lang]
      local path = dir .. "/" .. snippet[1]
      vim.fn.writefile(snippet[2], path)
      local p = tools.grep({ cwd = dir, query = "needle", debounce_ms = 0, preview = { enabled = false } })
      ready(p, path)
      local got = captures(p)
      assert(#got > 0, "no " .. lang .. " captures")
      if lang == "html" and pcall(vim.treesitter.language.add, "javascript") then
        assert(
          vim.tbl_contains(
            vim.tbl_map(function(c)
              return c.hl
            end, got),
            "@string.javascript"
          ),
          "injected JS string lost its context"
        )
      end
      p:close()
    end)
  else
    print("SKIP optional " .. lang .. " parser/query not installed")
  end
end
vim.fn.delete(fixture, "rf")
print(("%d syntax tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
