vim.opt.rtp:prepend(vim.fn.getcwd())
local api, tools = vim.api, require("selection_tools")
local function drain()
  vim.wait(30, function()
    return false
  end, 1)
end
local origin = api.nvim_get_current_win()
local callbacks, contexts = {}, {}
local parent = tools.open({
  items = { "alpha", "beta", "gamma" },
  multi = true,
  actions = { custom = function() end },
  keys = { custom = { "<F7>" } },
  action_descriptions = { custom = "Custom parent action" },
  on_choice = function(item)
    callbacks[#callbacks + 1] = item or "cancel"
  end,
})
assert(vim.fn.maparg("<C-n>", "i", false, true).desc == "[Picker] Next result")
assert(vim.fn.maparg("<F7>", "i", false, true).desc == "[Picker] Custom parent action")
parent:move(1)
parent:toggle()
local input, list = parent.input_buf, parent.list_buf
local child = tools.open({ nested = true, items = { "child" } })
drain()
assert(not parent.closed and parent.child == child and child.parent == parent)
assert(tools.current() == child and tools.current(parent.input_win) == parent)
assert(api.nvim_win_get_config(child.frame_win).zindex > api.nvim_win_get_config(parent.list_win).zindex)
local grandchild = tools.open({ nested = true, items = { "grandchild" } })
drain()
assert(not child.closed and tools.current() == grandchild)
grandchild:close()
drain()
assert(tools.current() == child and not parent.closed)
child:close()
drain()
assert(tools.current() == parent and not parent.child and #callbacks == 0)
assert(parent.input_buf == input and parent.list_buf == list and parent.index == 2 and parent.marks[2])
-- Child state never overwrites the ordinary resume source.
child = tools.open({ nested = true, items = { "child" } })
local replacement = tools.open({ items = { "replacement" } })
drain()
assert(parent.closed and child.closed and not replacement.closed and #callbacks == 1)
replacement:close()
drain()
assert(require("selection_tools.state").get().items[1] == "replacement")
assert(not pcall(tools.open, { nested = true, items = {} }))
assert(api.nvim_get_current_win() == origin)
-- Background deliveries are held until return, preserving item identity and marks.
parent = tools.open({
  finder = function(ctx)
    contexts[#contexts + 1] = ctx
  end,
  format_item = function(item)
    return item.text
  end,
  multi = true,
})
local one, two = { key = "one", text = "one" }, { key = "two", text = "two" }
contexts[1].set_items({ one, two })
drain()
parent:move(1)
parent:toggle()
child = tools.open({ nested = true, items = { "child" } })
contexts[1].set_items({ { key = "zero", text = "zero" }, one, two })
contexts[1].done()
drain()
assert(parent:current() == two and parent.index == 2 and parent.marks[2])
child:close()
drain()
assert(parent:current() == two and parent.index == 3 and parent.marks[3] and not parent.loading)
child = tools.open({ nested = true, items = { "child" } })
parent:set_items({ two, one })
assert(parent:current() == two and parent.index == 3 and parent.marks[3])
child:close()
drain()
assert(parent:current() == two and parent.index == 1 and parent.marks[1])
child = tools.open({ nested = true, items = { "child" } })
parent:close()
drain()
assert(parent.closed and child.closed and tools.current() == nil)
parent = tools.open({ items = { "parent" } })
child = tools.open({ nested = true, items = { "child" } })
local windows = #api.nvim_list_wins()
assert(not pcall(tools.open, {
  nested = true,
  items = { "bad" },
  format_item = function()
    error("bad formatter")
  end,
}))
assert(not parent.closed and not child.closed and #api.nvim_list_wins() == windows)
assert(not pcall(tools.open, { nested = true, items = { "bad" }, keys = { missing_action = { "<F8>" } } }))
drain()
assert(not parent.closed and not child.closed and tools.current() == child and #api.nvim_list_wins() == windows)
tools.dispose()
drain()
assert(parent.closed and child.closed and tools.current() == nil and api.nvim_get_current_win() == origin)
print(
  "PASS nested picker ownership, callbacks, descriptions, validation, replacement, async identity/marks and disposal"
)
