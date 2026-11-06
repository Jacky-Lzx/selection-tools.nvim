vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local api, tools = vim.api, require("selection_tools")
assert(not package.loaded["selection_tools.component_row"], "components should load on use")
local C = require("selection_tools.components")
local passed, failed, notices = 0, 0, {}
vim.notify = function(message)
  notices[#notices + 1] = message
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function lines(p)
  return api.nvim_buf_get_lines(p.list_buf, 0, -1, false)
end
local function spans(p, group)
  local result = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
    if mark[4].hl_group == group then
      local line = lines(p)[mark[2] + 1]
      result[#result + 1] = line:sub(mark[3] + 1, mark[4].end_col)
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
local function ready(p)
  assert(
    vim.wait(3000, function()
      return not p.loading and not p.matching and not p.syntax_pending
    end, 1),
    "picker did not settle"
  )
  assert(not p.error, p.error)
end

test("built-in components preserve source identity and separate searchable data from decorations", function()
  local item = { file = "src/中文.lua", pos = { 12, 4 }, text = "hello", timestamp = 1700000000 }
  local snapshot, chosen = vim.deepcopy(item)
  local p = tools.open({
    items = { item },
    components = { C.icon(), C.path({ path_format = false }), C.position(), C.text(), C.time({ format = "%H:%M" }) },
    format_icon = function()
      return "λ", "Special"
    end,
    on_choice = function(value, index)
      chosen = { value, index }
    end,
  })
  eq(p.entries[1].text, "src/中文.lua 12:5 hello")
  eq(spans(p, "SelectionToolsPath"), { "src/中文.lua" })
  eq(spans(p, "SelectionToolsPosition"), { "12:5" })
  eq(spans(p, "SelectionToolsTime"), { os.date("%H:%M", item.timestamp) })
  eq(spans(p, "Special"), { "λ" })
  p:set_query("12:5")
  eq(table.concat(spans(p, "SelectionToolsMatch")), "12:5")
  p:confirm()
  assert(chosen[1] == item and chosen[2] == 1)
  eq(item, snapshot)
end)

test("global defaults and per-component overrides are isolated and keep theme ownership", function()
  tools.setup({ component_defaults = { path = { hl = "Comment", max_width = 15 } } })
  local spec = C.path({ path_format = false, hl = "Special" })
  local snapshot = vim.deepcopy(spec)
  api.nvim_set_hl(0, "SelectionToolsTime", { fg = "#123456" })
  local p = tools.open({ items = { { file = "one.lua", timestamp = 1 } }, components = { spec, C.time() } })
  eq(spans(p, "Special"), { "one.lua" })
  eq(api.nvim_get_hl(0, { name = "SelectionToolsTime", link = false }).fg, 0x123456)
  eq(spec, snapshot)
  p:close()
  p = tools.open({ items = { { file = "two.lua" } }, components = { C.path({ path_format = false }) } })
  eq(spans(p, "Comment"), { "two.lua" })
  p:close()
  p = tools.open({ items = { { file = "three.lua" } }, components = { C.path({ hl = false }) } })
  eq(spans(p, "SelectionToolsPath"), {})
  eq(spans(p, "Comment"), {})
end)

test("display getters and highlighters run only for visible candidates and reuse caches", function()
  local calls, highlights, items = 0, 0, {}
  for i = 1, 10000 do
    items[i] = { text = "candidate" .. i }
  end
  local p = tools.open({
    items = items,
    components = {
      C.text(),
      C.text({
        searchable = false,
        get = function(item)
          calls = calls + 1
          return item.text
        end,
        highlights = function()
          highlights = highlights + 1
          return { { 0, 9, hl = "Special" } }
        end,
      }),
    },
  })
  eq(calls, p.height)
  eq(highlights, p.height)
  assert(not p.entries[p.height + 1].component_chunks)
  p:_render()
  eq(calls, p.height)
  eq(highlights, p.height)
  p.index = p.height + 1
  p:_render()
  eq(calls, p.height + 1)
  p.index = 1
  p:_render()
  eq(calls, p.height + 1)
  p:set_items({ items[1] })
  eq(calls, p.height + 2)
end)

test("component-local raw ranges and query offsets survive control escaping and Unicode", function()
  local raw = "head\t中文é\r\0\nneedle"
  local first = assert(raw:find("中文", 1, true)) - 1
  local item = { text = raw, pos = { 3, 4 } }
  local p = tools.open({
    items = { item },
    multi = true,
    highlight_item = function()
      local start = #"3:5 " + assert(raw:find("needle", 1, true)) - 1
      return { { start, start + #"needle", hl = "DiagnosticWarn", priority = 100 } }
    end,
    components = {
      C.position(),
      C.text({
        grow = 1,
        highlights = function()
          return { { first, first + #"中文é", hl = "Function" } }
        end,
      }),
    },
    layout = { width = 75 },
  })
  eq(spans(p, "Function"), { "中文é" })
  eq(spans(p, "DiagnosticWarn"), { "needle" })
  p:set_query("needle")
  eq(table.concat(spans(p, "SelectionToolsMatch")), "needle")
  p:toggle()
  eq(table.concat(spans(p, "SelectionToolsMatch")), "needle")
  eq(spans(p, "Function"), { "中文é" })
  assert(lines(p)[1]:find("● │ 3:5", 1, true))
end)

test("file-context syntax maps onto display-only code without a flattened content offset", function()
  local queries = vim.fn.stdpath("data") .. "/lazy/nvim-treesitter/runtime"
  if vim.fn.isdirectory(queries) == 1 then
    vim.opt.runtimepath:append(queries)
  end
  local path = vim.fn.tempname() .. ".lua"
  local code = '\tlocal message = "needle"'
  vim.fn.writefile({ code }, path)
  local ok, err = xpcall(function()
    local p = tools.open({
      items = { { file = path, pos = { 1, 0 }, code = code, text = "alias" } },
      syntax = { enabled = true },
      components = { C.text(), C.text({ field = "code", searchable = false, grow = 1 }) },
    })
    ready(p)
    local captured = false
    for _, mark in ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
      if mark[4].hl_group:match("^@keyword") then
        local line = lines(p)[mark[2] + 1]
        captured = captured or line:sub(mark[3] + 1, mark[4].end_col) == "local"
      end
    end
    assert(captured, "file syntax did not reach the code component")
    eq(p.entries[1].text, "alias")
    eq(vim.fn.bufnr(path), -1)
    p:close()
  end, debug.traceback)
  vim.fn.delete(path)
  assert(ok, err)
end)

test("path tail and match-centered text clipping map highlights without touching source data", function()
  local item = { file = string.rep("deep/", 20) .. "中文é.lua", text = string.rep("context ", 40) .. "needle tail" }
  local p = tools.open({
    items = { item },
    components = { C.path({ min_width = 14, max_width = 16, grow = 0 }), C.text({ truncate = "match", grow = 1 }) },
    layout = { width = 44 },
  })
  local original = p.entries[1].text
  p:set_query("needle")
  eq(table.concat(spans(p, "SelectionToolsMatch")), "needle")
  assert(lines(p)[1]:find("中文é.lua", 1, true))
  for _, cells in ipairs({ 24, 12, 65, 44 }) do
    p.opts.layout.width = cells
    p:resize()
    assert(vim.fn.strwidth(lines(p)[1]) <= p.resolved.width)
    eq(table.concat(spans(p, "SelectionToolsMatch")), "needle")
    eq(p.entries[1].text, original)
    assert(p:current() == item)
  end
  p:set_query("deep")
  assert(p:current() == item, "truncated path lost searchable content")
end)

test("narrow layouts hide low-priority components, align wide glyphs and remove absent gaps", function()
  local items = { { text = "中文é", pos = { 1, 0 } }, { text = "other", pos = { 1234, 999 } } }
  local p = tools.open({
    items = items,
    components = { C.icon(), C.text({ grow = 1 }), C.position({ align = "right" }) },
    format_icon = function(item)
      return item == items[1] and "λ" or "🦀", "Special"
    end,
    layout = { width = 45 },
  })
  local a, b = lines(p)[1], lines(p)[2]
  eq(vim.fn.strwidth(a), vim.fn.strwidth(b))
  eq(
    vim.fn.strwidth(a:sub(1, assert(a:find("中文", 1, true)) - 1)),
    vim.fn.strwidth(b:sub(1, assert(b:find("other", 1, true)) - 1))
  )
  p.opts.layout.width = 12
  p:resize()
  for _, line in ipairs(lines(p)) do
    assert(vim.fn.strwidth(line) <= 12)
  end
  p:close()
  p = tools.open({ items = { { text = "only" } }, components = { C.time(), C.text(), C.position() } })
  eq(lines(p), { "only" })
  p:close()
  p = tools.open({ items = { { text = "false flag", flag = false } }, components = { C.text({ field = "flag" }) } })
  eq(lines(p), { "false" })
end)

test("explicit search text stays independent of display and does not invent query highlights", function()
  local calls = 0
  local item = { text = "Visible title", aliases = "hidden alias" }
  local p = tools.open({
    items = { item },
    components = {
      C.text({
        get = function(value)
          calls = calls + 1
          return value.text
        end,
      }),
    },
    match_text = function(value)
      return value.aliases
    end,
  })
  eq(calls, 1)
  p:set_query("alias")
  assert(p:current() == item)
  eq(lines(p), { "Visible title" })
  eq(spans(p, "SelectionToolsMatch"), {})
  eq(calls, 1)
end)

test("component lists replace source defaults and legacy formatting remains available", function()
  tools.register_source("component_test", {
    items = { { text = "alpha", file = "alpha.lua" } },
    components = { C.icon(), C.path(), C.time() },
    format_item = function(item)
      return "legacy " .. item.text
    end,
  })
  local p = tools.pick("component_test", { components = { C.text() } })
  eq(#p.components.specs, 1)
  eq(lines(p), { "alpha" })
  p:close()
  p = tools.pick("component_test", { components = false })
  assert(not p.components)
  assert(lines(p)[1]:find("legacy alpha", 1, true))
  p:close()
  p = tools.pick("component_test", { components = {} })
  eq(lines(p), { "" })
  p:close()
  p = tools.buffers({
    format_item = function()
      return "custom buffer"
    end,
  })
  assert(not p.components)
  assert(lines(p)[1]:find("custom buffer", 1, true))
end)

test("streamed appends retain identities and marks while replacements discard component caches", function()
  local ctx
  local a, b = { text = "alpha" }, { text = "beta" }
  local p = tools.open({
    components = { C.text() },
    multi = true,
    match = false,
    finder = function(context)
      ctx = context
    end,
  })
  ctx.append_items({ a })
  assert(vim.wait(1000, function()
    return #p.entries == 1
  end, 1))
  p:toggle()
  ctx.append_items({ b })
  ctx.done()
  ready(p)
  assert(p.entries[2].item == b and p.entries[2].index == 2)
  assert(p:selected()[1] == a)
  b.text = "updated"
  p:set_items({ b })
  eq(lines(p), { "updated" })
  eq(p.entries[1].text, "updated")
end)

test("component search supports skim with Unicode and hidden metadata", function()
  if vim.fn.executable("sk") == 0 then
    return
  end
  local item = { text = "中文 beta", timestamp = 1 }
  local p = tools.open({
    items = { { text = "other" }, item },
    components = { C.time(), C.text() },
    matcher = { backend = "skim", skim = { debounce_ms = 0 } },
  })
  p:set_query("中文")
  ready(p)
  eq(p.match_backend, "skim")
  assert(p:current() == item)
  eq(table.concat(spans(p, "SelectionToolsMatch")), "中文")
end)

test("invalid descriptors preserve existing pickers and display callback errors stay recoverable", function()
  local p = tools.open({ items = { "existing" } })
  for _, spec in ipairs({
    C.text({ max_width = -1 }),
    C.path({ get = false }),
    C.icon({ searchable = true }),
    { kind = "missing" },
  }) do
    assert(not pcall(tools.open, { items = { "bad" }, components = { spec } }))
    assert(not p.closed)
  end
  local before = #notices
  p:close()
  p = tools.open({
    items = { "alpha", "beta" },
    components = {
      C.text(),
      C.text({
        searchable = false,
        get = function()
          error("display failure")
        end,
      }),
      C.text({
        searchable = false,
        get = function()
          return "label"
        end,
        highlights = function()
          error("highlight failure")
        end,
      }),
    },
  })
  eq(#notices, before + 2)
  p:_render()
  eq(#notices, before + 2)
  p:set_query("beta")
  eq(p:current(), "beta")
end)

print(("components: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
