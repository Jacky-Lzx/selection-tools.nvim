vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local api, tools = vim.api, require("selection_tools")
local source = "\tlocal original = true"
local label = "  中文é函数 [Function]"
local item =
  { file = "/tmp/content-columns.lua", pos = { 12, 4 }, code = source, display_code = label, display_indent = true }
local prefix = "content-columns.lua:12:5: "
local p = tools.open({
  items = { item },
  result_layout = "grep",
  syntax = { enabled = false },
  format_item = function(value)
    return prefix .. value.display_code
  end,
  highlight_item = function()
    return { { #prefix + 2, #prefix + 2 + #"中文é函数", hl = "Function", priority = 100 } }
  end,
  format_icon = function()
    return "L", "Special"
  end,
  layout = { width = 70, height = 5 },
})
local line = api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1]
assert(line:sub(1, #label) == label, "display content preserves symbol indentation")
assert(vim.fn.strwidth(line) == p.resolved.width, "location column reaches right edge")
assert(item.code == source, "semantic labels do not replace source code")
local semantic, location
for _, mark in ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
  if mark[4].hl_group == "Function" then
    semantic = mark
  end
  if mark[4].hl_group == "SelectionToolsFileLocation" then
    location = mark
  end
end
assert(semantic and location and semantic[4].end_col <= location[3], "semantic colors stay in content column")
assert(line:sub(semantic[3] + 1, semantic[4].end_col) == "中文é函数", "Unicode semantic offsets survive layout")
p:set_query("函数")
local matched = false
for _, mark in ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
  if mark[4].hl_group == "SelectionToolsMatch" then
    assert(mark[4].priority > semantic[4].priority, "query matches take priority over semantic colors")
    matched = true
  end
end
assert(matched)
p:close()

item.display_code = "alpha " .. string.rep("context ", 30) .. "needle"
item.display_indent = false
p = tools.open({
  items = { item },
  result_layout = "grep",
  syntax = { enabled = false },
  format_item = function(value)
    return prefix .. value.display_code
  end,
  highlight_item = function()
    return { { #prefix, #prefix + #item.display_code, hl = "Function", priority = 100 } }
  end,
  item_icons = false,
  layout = { width = 50, height = 5 },
})
p:set_query("alpha")
assert(api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1]:find("alpha", 1, true))
p:set_query("needle")
assert(
  api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1]:find("needle", 1, true),
  "changing query on the same entry recomputes clipped content around the hit"
)
for _, cells in ipairs({ 24, 12, 80 }) do
  p.opts.layout.width = cells
  p:resize()
  for _, text in ipairs(api.nvim_buf_get_lines(p.list_buf, 0, -1, false)) do
    assert(vim.fn.strwidth(text) <= p.resolved.width, "content never overlaps narrow borders")
  end
end
p:close()
print("content columns: semantic highlights, source identity, Unicode, query clipping and narrow layouts passed")
vim.cmd("qa!")
