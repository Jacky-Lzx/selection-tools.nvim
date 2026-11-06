vim.opt.rtp:prepend(vim.fn.getcwd())
local tools, api = require("selection_tools"), vim.api
local notices, changes = {}, {}
vim.notify = function(message)
  notices[#notices + 1] = message
end
local first, second = { text = "alpha" }, { text = "beta" }
local picker = tools.select({ first, second }, {
  resume = false,
  format_item = function(item)
    return item.text
  end,
  on_change = function(item, index, p)
    changes[#changes + 1] = { item = item, index = index }
    assert(p:current() == item)
  end,
}, function() end)
assert(#changes == 1 and changes[1].item == first and changes[1].index == 1)
picker:resize()
assert(#changes == 1, "resize must not repeat selection callbacks")
picker:move(1)
assert(#changes == 2 and changes[2].item == second and changes[2].index == 2)
picker:set_query("beta")
assert(#changes == 2, "same original selection must not repeat callbacks")
picker:set_query("no matches")
assert(#changes == 3 and changes[3].item == nil and changes[3].index == nil)
picker:set_query("beta")
assert(#changes == 4 and changes[4].item == second and changes[4].index == 2)
picker:set_items({ second, first })
assert(#changes == 5 and changes[5].item == second and changes[5].index == 1)
picker:close()
picker:move(1)
assert(#changes == 5)
picker = tools.select({ "one", "two" }, {
  on_change = function()
    error("bad change callback")
  end,
}, function() end)
assert(not picker.closed and notices[#notices]:find("bad change callback", 1, true))
picker:move(1)
assert(picker:current() == "two")
vim.cmd.colorscheme("morning")
assert(
  vim.deep_equal(
    api.nvim_get_hl(0, { name = "SelectionToolsSelected", link = false }),
    api.nvim_get_hl(0, { name = "Visual", link = false })
  ),
  "selected-row colors should follow Visual after a colorscheme change"
)
picker:close()
-- Pending matching must not expose a selection that has not been published.
local done
changes = {}
picker = tools.select({ "alpha", "beta" }, {
  on_change = function(item)
    changes[#changes + 1] = item
  end,
}, function() end)
picker.matcher.select = function()
  return "skim"
end
picker.matcher.run = function(_, _, _, callback)
  done = callback
end
picker:set_query("beta")
assert(picker.matching and #changes == 1 and changes[1] == "alpha")
picker:resize()
assert(#changes == 1)
done({ picker.entries[2] }, {}, "skim")
assert(#changes == 2 and changes[2] == "beta")
picker:close()
picker = tools.select({ "alpha" }, {
  on_change = function(_, _, p)
    p:close()
  end,
}, function() end)
assert(picker.closed, "callback can close the initial picker without leaking windows")
assert(#api.nvim_list_wins() == 1)
print("selection change callbacks, identity, errors, pending results and colorscheme refresh passed")
