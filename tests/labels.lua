vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local tools = require("selection_tools")
local function dividers(p)
  return api.nvim_buf_get_lines(p.separator_buf, 0, -1, false)
end
local function title(p)
  local config = api.nvim_win_get_config(p.frame_win)
  return config.title and config.title[1][1], config.title_pos
end
local function body(text, alignment, width)
  local space = width - vim.fn.strdisplaywidth(text) - 2
  local before = alignment == "center" and math.floor(space / 2) or (alignment == "right" and space - 1 or 1)
  return "├" .. string.rep("─", before) .. " " .. text .. " " .. string.rep("─", space - before) .. "┤"
end
local function open(labels, extra)
  return tools.open(vim.tbl_deep_extend("force", {
    prompt = "Default title",
    items = { "alpha", "beta" },
    preview = { enabled = true },
    layout = { height = 0.9, input_position = "bottom", labels = labels },
  }, extra or {}))
end
for _, input in ipairs({ "top", "bottom" }) do
  for _, align in ipairs({ "left", "center", "right" }) do
    local p = open({
      top = { text = "Title", align = align },
      middle = { text = "目录_é", align = align },
      bottom = { text = "Filters", align = align },
    }, { layout = { input_position = input } })
    local text, actual_align = title(p)
    assert(text == " Title " and actual_align == align)
    assert(dividers(p)[1] == body("目录_é", align, p.resolved.width))
    assert(dividers(p)[2] == body("Filters", align, p.resolved.width))
    local columns = vim.o.columns
    vim.o.columns = 16
    p:resize()
    for _, line in ipairs(dividers(p)) do
      assert(vim.fn.strdisplaywidth(line) == p.resolved.width + 2)
    end
    vim.o.columns = columns
    p:close()
  end
end
local p = open({
  top = {
    text = function(picker, default)
      return default .. ":" .. picker.query
    end,
    align = "right",
  },
  middle = { text = false },
  bottom = {
    text = function(picker)
      return picker.query == "" and "all" or "query:" .. picker.query
    end,
    align = "left",
  },
})
assert(title(p) == " Default title: ")
assert(dividers(p)[1] == "├" .. string.rep("─", p.resolved.width) .. "┤")
p:set_query("beta")
assert(title(p) == " Default title:beta ")
assert(dividers(p)[2] == body("query:beta", "left", p.resolved.width))
p:close()
p = tools.resume()
assert(title(p) == " Default title:beta ")
p:close()
local notifications, notify = {}, vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
p = open({
  top = {
    text = function()
      error("bad label")
    end,
  },
  middle = {
    text = function()
      return {}
    end,
  },
  bottom = {
    text = function()
      return nil
    end,
  },
})
assert(title(p) == " Default title ")
assert(#notifications == 2)
p:set_query("alpha")
assert(#notifications == 2)
p:close()
vim.notify = notify
tools.setup({
  layout = { labels = { top = { text = "Global", align = "right" }, bottom = { text = "Global footer" } } },
})
p = tools.open({ items = { "one" }, layout = { labels = { top = { align = "left" } } } })
local text, align = title(p)
assert(text == " Global " and align == "left")
assert(#dividers(p) == 1 and dividers(p)[1]:find("Global footer", 1, true))
p:close()
tools.setup()
p = open({ top = { text = false }, bottom = { text = "" } }, { preview = { enabled = false } })
assert(title(p) == nil)
assert(#dividers(p) == 1 and dividers(p)[1] == "├" .. string.rep("─", p.resolved.width) .. "┤")
p:close()
for _, labels in ipairs({
  "bad",
  { unknown = {} },
  { top = "bad" },
  { top = { align = "bad" } },
  { bottom = { text = 5 } },
}) do
  local windows = api.nvim_list_wins()
  assert(not pcall(open, labels))
  assert(vim.deep_equal(api.nvim_list_wins(), windows), "Invalid labels leaked a window")
end
print(
  "PASS border label API: independent content/alignment, physical rows, callbacks, hiding, resize, resume, global/per-call overrides and validation"
)
vim.cmd.qa({ bang = true })
