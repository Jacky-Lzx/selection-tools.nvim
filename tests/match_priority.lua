vim.opt.rtp:prepend(vim.fn.getcwd())
local tools = require("selection_tools")
local global = { text = "abc", priority = 1 }
local local_item = { text = "a---b---c", priority = 0 }
local second = { text = "ab c", priority = 1 }
local picker = tools.open({
  items = { global, local_item, second },
  format_item = function(item)
    return item.text
  end,
  match_priority = function(item)
    return item.priority
  end,
})
assert(picker.matches[1].item == local_item and picker.matches[2].item == global)
picker:set_query("abc")
assert(picker.matches[1].item == local_item, "Local group lost to an exact global match")
assert(picker.matches[2].item == global and picker.matches[3].item == second, "Within-group relevance changed")
local expected = vim.fn.matchfuzzypos({ local_item.text }, "abc", { matchseq = 1 })[2][1]
assert(vim.deep_equal(picker.positions[1], expected), "Highlight offsets moved to another item")
local done
picker.matcher.select = function()
  return "skim"
end
picker.matcher.run = function(_, _, _, callback)
  done = callback
end
picker:set_query("ab")
assert(picker.matching)
done({ picker.entries[1], picker.entries[3], picker.entries[2] }, { { 0, 1 }, { 0, 1 }, { 0, 4 } }, "skim")
assert(picker.matches[1].item == local_item and picker.matches[2].item == global and picker.matches[3].item == second)
assert(vim.deep_equal(picker.positions[1], { 0, 4 }) and vim.deep_equal(picker.positions[2], { 0, 1 }))
picker:set_query("")
assert(picker.matches[1].item == local_item and picker.entries[1].item == global, "Priority sort mutated source order")
assert(not pcall(tools.open, { items = {}, match_priority = "invalid" }) and not picker.closed)
picker:close()
local context
picker = tools.open({
  match = false,
  finder = function(ctx)
    context = ctx
  end,
  format_item = function(item)
    return item.text
  end,
  match_priority = function(item)
    return item.priority
  end,
})
context.append_items({ global })
assert(vim.wait(200, function()
  return #picker.entries == 1
end))
context.append_items({ local_item, second })
context.done()
assert(vim.wait(200, function()
  return #picker.entries == 3 and not picker.loading
end))
assert(picker.matches[1].item == local_item and picker.matches[2].item == global and picker.matches[3].item == second)
picker:close()
print("PASS stable match priority groups, native/async/streamed relevance, highlight alignment and original indices")
