vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local api, tools, C = vim.api, require("selection_tools"), require("selection_tools.components")
local passed, failed = 0, 0
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function lines(p)
  return api.nvim_buf_get_lines(p.list_buf, 0, -1, false)
end
local function marks(p, group)
  local result = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
    if mark[4].hl_group == group then
      local line = lines(p)[mark[2] + 1]
      result[#result + 1] =
        { row = mark[2], text = line:sub(mark[3] + 1, mark[4].end_col), first = mark[3], last = mark[4].end_col }
    end
  end
  return result
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  tools.dispose()
  tools.setup()
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end
local function open(items, opts)
  return tools.open(vim.tbl_extend("force", {
    items = items,
    components = { C.text({ grow = 1, truncate = "match" }) },
    layout = { width = 70, height = 12 },
  }, opts or {}))
end

test("contiguous Unicode matches coalesce while fuzzy gaps retain their original colors", function()
  local p = open({ "中文needle", "中文n e e d l e" })
  p:set_query("中文needle")
  local spans = marks(p, "SelectionToolsMatch")
  local painted = {}
  for _, mark in ipairs(spans) do
    painted[mark.row] = (painted[mark.row] or "") .. mark.text
    assert(not mark.text:find(" "), "fuzzy gaps were highlighted")
  end
  eq(painted[0], "中文needle")
  eq(painted[1], "中文needle")
  eq(spans[1].text, "中文needle")
  p:toggle()
  p:set_query("needle")
  spans = marks(p, "SelectionToolsMatch")
  eq(spans[1].text, "needle")
  p:set_query("中文")
  for _, mark in ipairs(marks(p, "SelectionToolsMatch")) do
    eq(mark.text, "中文")
  end
end)

test("bounded row and match caches reuse clipped rows and discard offscreen entries", function()
  local items = {}
  for i = 1, 1000 do
    items[i] = { text = string.rep("context ", 25) .. "needle " .. i }
  end
  local p = open(items)
  p:set_query("needle")
  local entry = p.matches[1]
  local row = p.components.row_cache[entry].result
  local ranges = p.match_range_cache[entry].ranges
  p:_render()
  assert(p.components.row_cache[entry].result == row)
  assert(p.match_range_cache[entry].ranges == ranges)
  for index = p.height + 1, p.height * 5 do
    p.index = index
    p:_render()
    assert(vim.tbl_count(p.components.row_cache) <= p.height)
    assert(vim.tbl_count(p.match_range_cache) <= p.height)
  end
  assert(not p.components.row_cache[entry] and not p.match_range_cache[entry])
  p:set_items({ { text = "replacement needle" } })
  eq(lines(p), { "replacement needle" })
  eq(vim.tbl_count(p.components.row_cache), 1)
  eq(vim.tbl_count(p.match_range_cache), 1)
end)

test("cached layout and spans invalidate for query, marks, width, icons and character widths", function()
  local icon, hl = "λ", "Special"
  local p = open({ { text = string.rep("前文· ", 20) .. "needle trailing" } }, {
    multi = true,
    components = { C.icon(), C.text({ grow = 1, truncate = "match" }) },
    format_icon = function()
      return icon, hl
    end,
  })
  p:set_query("needle")
  local function painted()
    local chunks = {}
    for _, mark in ipairs(marks(p, "SelectionToolsMatch")) do
      chunks[#chunks + 1] = mark.text
    end
    return table.concat(chunks)
  end
  eq(painted(), "needle")
  p:toggle()
  assert(lines(p)[1]:find("● │ ", 1, true))
  eq(painted(), "needle")
  for _, width in ipairs({ 24, 80 }) do
    p.opts.layout.width = width
    p:resize()
    eq(painted(), "needle")
    assert(vim.fn.strwidth(lines(p)[1]) <= p.resolved.width)
  end
  hl = "DiagnosticWarn"
  api.nvim_exec_autocmds("User", { pattern = "ThemeToolsIconsChanged" })
  eq(marks(p, "DiagnosticWarn")[1].text, "λ")
  local old = vim.o.ambiwidth
  vim.o.ambiwidth = old == "single" and "double" or "single"
  p:_render()
  eq(painted(), "needle")
  vim.o.ambiwidth = old
  p:set_query("trailing")
  eq(painted(), "trailing")
end)

test("skim byte caches follow replacement results for repeated queries and duplicate labels", function()
  if vim.fn.executable("sk") == 0 then
    return
  end
  local a, b = { text = "中文 needle" }, { text = "中文 needle" }
  local p = open({ a, b }, { matcher = { backend = "skim", skim = { debounce_ms = 0 } } })
  local function ready()
    assert(vim.wait(3000, function()
      return not p.matching
    end, 1))
  end
  p:set_query("needle")
  ready()
  eq(#marks(p, "SelectionToolsMatch"), 2)
  p:set_items({ b, a })
  ready()
  assert(p:current() == b)
  p:set_query("中文")
  ready()
  for _, mark in ipairs(marks(p, "SelectionToolsMatch")) do
    eq(mark.text, "中文")
  end
end)

test("selection-only updates preserve content marks, preview and callback identity in both directions", function()
  for _, reverse in ipairs({ false, true }) do
    local items, changes = {}, {}
    for i = 1, 30 do
      items[i] = { text = "needle " .. i }
    end
    local p = open(items, {
      multi = true,
      preview = { enabled = true },
      layout = { width = 70, height = 22, reverse = reverse },
      previewer = function(ctx)
        ctx.set_lines({ "Preview " .. ctx.item.text })
      end,
      on_change = function(item, index)
        changes[#changes + 1] = { item, index }
      end,
    })
    p:set_query("needle")
    local tick = api.nvim_buf_get_changedtick(p.list_buf)
    local ns = api.nvim_create_namespace("selection_tools")
    local content = api.nvim_buf_get_extmarks(p.list_buf, ns, 0, -1, { details = true })
    local before = #changes
    p:move(1)
    eq(api.nvim_buf_get_changedtick(p.list_buf), tick)
    eq(api.nvim_buf_get_extmarks(p.list_buf, ns, 0, -1, { details = true }), content)
    eq(#changes, before + 1)
    assert(changes[#changes][1] == p:current())
    assert(
      vim.wait(1000, function()
        return api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "Preview " .. p:current().text
      end, 1),
      "selection-only update did not publish the new preview"
    )
    local selected = marks(p, "SelectionToolsSelected")
    eq(#selected, 1)
    eq(selected[1].row, reverse and p.height - 2 or 1)
    local count = api.nvim_buf_get_extmarks(
      p.frame_buf,
      api.nvim_create_namespace("selection_tools_count"),
      0,
      -1,
      { details = true }
    )
    eq(#count, 1)
    assert(count[1][4].virt_text[1][1]:find("2/30", 1, true))
    p:move(-1)
    eq(api.nvim_buf_get_changedtick(p.list_buf), tick)
    p:toggle()
    local marked_tick = api.nvim_buf_get_changedtick(p.list_buf)
    assert(marked_tick > tick, "new mark column did not rebuild content")
    p:move(1)
    eq(api.nvim_buf_get_changedtick(p.list_buf), marked_tick)
    p:move(p.height)
    assert(api.nvim_buf_get_changedtick(p.list_buf) > marked_tick, "scrolling failed to publish new rows")
    p:close()
  end
end)

test("dynamic titles and result counts still refresh without rewriting the list", function()
  local p = open({ "alpha", "beta" }, {
    layout = {
      width = 60,
      height = 12,
      labels = { top = {
        text = function(picker)
          return picker:current()
        end,
      } },
    },
  })
  local tick = api.nvim_buf_get_changedtick(p.list_buf)
  p:move(1)
  eq(api.nvim_buf_get_changedtick(p.list_buf), tick)
  eq(api.nvim_win_get_config(p.frame_win).title[1][1], " beta ")
  p:set_query("absent")
  eq(#marks(p, "SelectionToolsSelected"), 0)
  p:set_query("alpha")
  eq(#marks(p, "SelectionToolsSelected"), 1)
  p.opts.layout.width = 24
  p:resize()
  tick = api.nvim_buf_get_changedtick(p.list_buf)
  p:set_items({ "replacement" })
  assert(api.nvim_buf_get_changedtick(p.list_buf) > tick)
end)

test("a pending matcher keeps selection callbacks gated and publishes its completed result", function()
  local changes, done = {}, nil
  local p = open({ "alpha", "beta" }, {
    on_change = function(item)
      changes[#changes + 1] = item
    end,
  })
  p.matcher.select = function()
    return "skim"
  end
  p.matcher.run = function(_, _, _, callback)
    done = callback
  end
  p:set_query("beta")
  p:move(1)
  eq(#changes, 1)
  done({ p.entries[2] }, { { 0, 1, 2, 3 } }, "skim")
  eq(p:current(), "beta")
  eq(changes[#changes], "beta")
  eq(marks(p, "SelectionToolsMatch")[1].text, "beta")
end)

test("selection movement revalidates syntax when a loaded source buffer changed", function()
  local queries = vim.fn.stdpath("data") .. "/lazy/nvim-treesitter/runtime"
  if vim.fn.isdirectory(queries) == 1 then
    vim.opt.runtimepath:append(queries)
  end
  local path = vim.fn.tempname() .. ".lua"
  local code = 'print("needle")'
  local source = { "local before = 1", code, "-- end", code }
  vim.fn.writefile(source, path)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, path)
  api.nvim_buf_set_lines(buf, 0, -1, false, source)
  vim.bo[buf].filetype = "lua"
  local ok, err = xpcall(function()
    local p = open({
      { file = path, bufnr = buf, pos = { 2, 0 }, code = code },
      { file = path, bufnr = buf, pos = { 4, 0 }, code = code },
    }, { syntax = { enabled = true }, components = { C.text({ field = "code" }) } })
    assert(vim.wait(3000, function()
      return not p.syntax_pending
    end, 1))
    api.nvim_buf_set_lines(buf, 0, 1, false, { "local before = [[" })
    api.nvim_buf_set_lines(buf, 2, 3, false, { "]]" })
    local version = "buffer:" .. buf .. ":" .. api.nvim_buf_get_changedtick(buf)
    p:move(1)
    assert(
      vim.wait(3000, function()
        return not p.syntax_pending and p.syntax.files[path].version == version
      end, 1),
      "selection-only update failed to notice changed source syntax"
    )
    local strings = marks(p, "@string.lua")
    local captured = false
    for _, mark in ipairs(strings) do
      captured = captured or mark.row == 0 and mark.text:find("print", 1, true)
    end
    assert(captured, "new file-context colors did not repaint the unchanged code line")
    p:close()
  end, debug.traceback)
  api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
  assert(ok, err)
end)

print(("rendering: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
