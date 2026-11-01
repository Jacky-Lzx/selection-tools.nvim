vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local passed, failed = 0, 0
local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function ready(p)
  assert(
    vim.wait(3000, function()
      return not p.loading and not p.matching
    end, 1),
    "source timed out"
  )
  assert(not p.error, p.error)
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
local function provider(value, fn)
  local loaded, preload = package.loaded["nvim-web-devicons"], package.preload["nvim-web-devicons"]
  local loads = 0
  package.loaded["nvim-web-devicons"] = nil
  package.preload["nvim-web-devicons"] = function()
    loads = loads + 1
    if value == false then
      error("optional provider missing")
    end
    return value
  end
  local ok, err = xpcall(function()
    fn(function()
      return loads
    end)
  end, debug.traceback)
  package.loaded["nvim-web-devicons"], package.preload["nvim-web-devicons"] = loaded, preload
  assert(ok, err)
end
local function open(items, opts)
  return tools.open(vim.tbl_extend("force", {
    items = items,
    format_item = function(item)
      return item.text
    end,
    layout = { reverse = false },
  }, opts or {}))
end
local function marks(p, group)
  return vim.tbl_filter(function(mark)
    return mark[4].hl_group == group
  end, vim.api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true }))
end

test("startup and plain selection do not load icon modules or optional providers", function()
  assert(not package.loaded["selection_tools.item_icons"])
  provider({}, function(loads)
    local p = tools.select({ "plain" }, {}, function() end)
    assert(not package.loaded["selection_tools.item_icons"])
    eq(loads(), 0)
    p:close()
  end)
end)

test("only visible file icons are resolved and revisiting rows reuses results", function()
  local calls = 0
  provider({
    get_icon = function()
      calls = calls + 1
      return "λ", "Special"
    end,
  }, function(loads)
    local items = {}
    for i = 1, 10000 do
      items[i] = { text = "file" .. i .. ".lua", file = "file" .. i .. ".lua" }
    end
    local p = open(items)
    eq(loads(), 1)
    eq(calls, p.height)
    eq(vim.api.nvim_buf_get_lines(p.list_buf, 0, 1, false), { " λ file1.lua" })
    p:_render()
    eq(calls, p.height)
    p.index = p.height + 1
    p:_render()
    eq(calls, p.height + 1)
    p.index = 1
    p:_render()
    eq(calls, p.height + 1)
    eq(p.entries[1].text, "file1.lua")
    p:close()
  end)
end)

test("icon widths align labels and Unicode match highlights use byte offsets after icons", function()
  local items = { { text = "βeta", icon = "λ" }, { text = "other", icon = "🦀" }, { text = "plain" } }
  local p = open(items, {
    multi = true,
    format_icon = function(item)
      return item.icon, "Special"
    end,
  })
  local lines = vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false)
  for i, item in ipairs(items) do
    local start = assert(lines[i]:find(item.text, 1, true))
    eq(vim.fn.strdisplaywidth(lines[i]:sub(1, start - 1)), 4)
  end
  eq(#marks(p, "Special"), 2)
  p:set_query("β")
  local line = vim.api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1]
  eq(line, " λ βeta")
  local match = marks(p, "SelectionToolsMatch")[1]
  local start = assert(line:find("β", 1, true)) - 1
  eq(match[3], start)
  eq(match[4].end_col, start + #"β")
  local icon = marks(p, "Special")[1]
  eq(icon[3], 1)
  eq(icon[4].end_col, #" λ")
  p:toggle()
  line = vim.api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1]
  eq(line, "● │ λ βeta")
  icon = marks(p, "Special")[1]
  eq(icon[3], #"● │ ")
  eq(icon[4].end_col, #"● │ λ")
  match = marks(p, "SelectionToolsMatch")[1]
  eq(line:sub(match[3] + 1, match[4].end_col), "β")
  p:set_query("λ")
  eq(#p.matches, 0)
  p:close()
end)

test("icon decoration preserves duplicate identities, selection indices and copied paths", function()
  local items = { { text = "duplicate", file = "/tmp/first.lua" }, { text = "duplicate", file = "/tmp/second.lua" } }
  local chosen, copied
  local setreg = vim.fn.setreg
  vim.fn.setreg = function(register, value)
    if register == "+" then
      copied = value
    else
      return setreg(register, value)
    end
  end
  local ok, err = xpcall(function()
    local p = open(items, {
      multi = true,
      layout = { reverse = true },
      format_icon = function(_, index)
        return index == 1 and "λ" or "🦀", "Special"
      end,
      on_choice = function(item, index, selected)
        chosen = { item, index, selected }
      end,
    })
    p:set_query("duplicate")
    p:move(1)
    p:toggle()
    eq(p:selected()[1], items[2])
    require("selection_tools.actions").copy(p)
    eq(copied, "/tmp/second.lua")
    p:confirm()
    assert(chosen[1] == items[2] and chosen[2] == 2 and chosen[3][1] == items[2])
  end, debug.traceback)
  vim.fn.setreg = setreg
  assert(ok, err)
end)

test("disabled icons skip providers and formatters and preserve the text-only list", function()
  provider({
    get_icon = function()
      error("must not be called")
    end,
  }, function(loads)
    for _, setting in ipairs({ false, { enabled = false } }) do
      local p = open({ { text = "file.lua", file = "file.lua" } }, {
        item_icons = setting,
        format_icon = function()
          error("must not be called")
        end,
      })
      eq(vim.api.nvim_buf_get_lines(p.list_buf, 0, -1, false), { "file.lua" })
      eq(loads(), 0)
      p:close()
    end
  end)
end)

test("provider lookup preserves exact filenames, compound extensions and buffer filetypes", function()
  local seen, by_ft = {}, 0
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lua"
  provider({
    get_icon = function(name, ext, opts)
      seen[#seen + 1] = name
      eq(ext, nil)
      assert(opts.strict)
      if name == "Dockerfile" then
        return "Ｄ", "Special"
      end
      if name == "file.test.lua" then
        return "λ", "Special"
      end
    end,
    get_icon_by_filetype = function(ft)
      by_ft = by_ft + 1
      eq(ft, "lua")
      return "λ", "Special"
    end,
  }, function()
    local p = open({
      { text = "Dockerfile", file = "Dockerfile" },
      { text = "file.test.lua", file = "file.test.lua" },
      { text = "unnamed", bufnr = buf },
    })
    eq(seen, { "Dockerfile", "file.test.lua" })
    eq(by_ft, 1)
    eq(#marks(p, "Special"), 3)
    p:close()
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("missing optional providers fall back to file and folder icons", function()
  provider(false, function(loads)
    local p = open({ { text = "project", dir = "/tmp" } })
    eq(loads(), 0)
    eq(#marks(p, "SelectionToolsDirectoryIcon"), 1)
    p:close()
    p = open({ { text = "one", file = "one.lua" }, { text = "two", file = "two.txt" } })
    eq(loads(), 1)
    eq(#marks(p, "SelectionToolsFileIcon"), 2)
    p:set_query("one")
    eq(loads(), 1)
    p:close()
  end)
end)

test("a failing custom icon formatter does not break selection and warns once", function()
  local count = #notifications
  local p = open({ { text = "one" }, { text = "two" } }, {
    format_icon = function()
      error("bad formatter")
    end,
  })
  eq(#notifications, count + 1)
  p:set_query("two")
  eq(p:current().text, "two")
  eq(#notifications, count + 1)
  p:close()
end)

if vim.fn.executable("sk") == 1 then
  test("real skim searches plain labels and retains Unicode icon highlight offsets", function()
    local first, second = { text = "βeta", file = "one.lua" }, { text = "βetamax", file = "two.lua" }
    local p = open({ first, second }, {
      matcher = { backend = "skim" },
      format_icon = function()
        return "🦀", "Special"
      end,
    })
    p:set_query("βta")
    ready(p)
    eq(p:matcher_status().backend, "skim")
    eq(#p.matches, 2)
    assert(not p.matcher.payload:find("🦀", 1, true))
    local line = vim.api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1]
    local match = marks(p, "SelectionToolsMatch")[1]
    eq(match[3], assert(line:find("β", 1, true)) - 1)
    p:set_query("🦀")
    ready(p)
    eq(#p.matches, 0)
    p:close()
  end)
end

print(("%d item icon tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
