vim.opt.rtp:prepend(vim.fn.getcwd())
local graph = require("selection_tools.sources.undo_tree")
local rows = require("selection_tools.undo_row")
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local history = graph.new({
  seq_cur = 6,
  save_last = 1,
  entries = {
    { seq = 1, time = 0, save = 1 },
    {
      seq = 4,
      time = 0,
      alt = {
        { seq = 2, time = 0 },
        { seq = 6, time = 0, alt = { { seq = 3, time = 0 }, { seq = 5, time = 0 } } },
      },
    },
    { seq = 7, time = 0 },
  },
})
local items, sequences, nodes = history(""), {}, {}
for _, item in ipairs(items) do
  sequences[#sequences + 1], nodes[item.seq] = item.seq, item
end
eq(sequences, { 7, 4, 6, 5, 3, 2, 1, 0 })
eq(nodes[4].parent, 1)
eq(nodes[2].parent, 1)
eq(nodes[6].parent, 2)
eq(nodes[3].parent, 2)
eq(nodes[5].parent, 3)
local drawings = {}
local time_column
for _, item in ipairs(items) do
  drawings[#drawings + 1] = item.graph:gsub("%s+$", "")
  local position = item.text:find(item.timestamp, 1, true)
  local column = vim.fn.strdisplaywidth(item.text:sub(1, position - 1))
  time_column = time_column or column
  eq(column, time_column)
  local mark = item.highlights[2]
  eq(item.text:sub(mark[1] + 1, mark[2]), item.current and "◆" or "●")
end
eq(drawings, { "●", "●", "│ ◆", "│ │ ●", "│ │ ●", "│ ●─╯", "●─╯", "●" })
assert(nodes[1].saved)
print(
  "PASS undo graph: nested sibling branches, interleaved edit times, shared ancestors, aligned columns, node highlights"
)

for _, ambiwidth in ipairs({ "single", "double" }) do
  vim.o.ambiwidth = ambiwidth
  for _, reverse in ipairs({ false, true }) do
    for _, width in ipairs({ 9, 44, 96 }) do
      for _, item in ipairs(history("")) do
        local rendered = rows.render({ item = item, text = item.text }, width, "", reverse)
        eq(vim.fn.strdisplaywidth(rendered.text), width)
        eq(rendered.text:sub(-#item.sequence), item.sequence)
        local seq = rendered.segments[2]
        eq(rendered.text:sub(seq[3] + 1), item.sequence)
        eq(item.highlights[3].hl, "Number")
        eq(item.text:sub(item.highlights[3][1] + 1, item.highlights[3][2]), item.timestamp)
        eq(item.highlights[5].hl, "Comment")
        eq(item.text:sub(item.highlights[5][1] + 1, item.highlights[5][2]), item.sequence)
        if width == 96 and item.graph:find("╯", 1, true) then
          assert(rendered.text:find(reverse and "╮" or "╯", 1, true))
        end
      end
    end
  end
end
vim.o.ambiwidth = "single"
print("PASS undo rows: primary time, muted right-aligned sequence, both graph directions and Unicode display widths")

local reference = graph.new({
  entries = {
    { seq = 236, time = 0 },
    {
      seq = 242,
      time = 0,
      alt = {
        { seq = 237, time = 0 },
        { seq = 240, time = 0, alt = { { seq = 238, time = 0 }, { seq = 239, time = 0 } } },
        { seq = 241, time = 0 },
      },
    },
  },
})("")
local forks = {}
for _, item in ipairs(reference) do
  forks[item.seq] = item.graph:gsub("╯", "╮"):gsub("%s+$", "")
end
eq(forks[236], "●─╮")
eq(forks[237], "│ ●─╮")
eq(forks[238], "│ │ ●")
eq(forks[239], "│ │ ●")
eq(forks[240], "│ ●")
eq(forks[241], "│ ●")
eq(forks[242], "●")
print("PASS undo graph: reference staircase forks leave parent #236/#237 and lead into child #237/#238")

local results = history("#5")
local path = {}
for _, item in ipairs(results) do
  path[#path + 1] = item.seq
  assert(item.graph == "● ", "Filtering must redraw the surviving ancestry")
  eq(item.context, item.seq ~= 5)
end
eq(path, { 5, 3, 2, 1, 0 })
local highlighted = {}
for _, range in ipairs(results[1].highlights) do
  if range.hl == "SelectionToolsMatch" then
    highlighted[#highlighted + 1] = results[1].text:sub(range[1] + 1, range[2])
  end
end
eq(highlighted, { "#", "5" })
eq(history("no-such-version"), {})
eq(history("#999"), {})
eq(#history(""), 8)
print(
  "PASS undo graph search: matching versions retain ancestor context and byte-correct query highlights; clearing restores branches"
)

local retained = graph.new({ seq_cur = 21, entries = { { seq = 20 }, { seq = 21, alt = { { seq = 19 } } } } })("")
eq(#retained, 3)
for _, item in ipairs(retained) do
  assert(item.seq ~= 0, "Pruned undo history must not invent the initial state")
end
local empty = graph.new({ seq_cur = 0, entries = {} })("")
eq(#empty, 1)
assert(empty[1].seq == 0 and empty[1].current and empty[1].graph == "◆ ")
print("PASS undo graph: pruned history and empty initial state")

-- Exercise Neovim's real alt representation after editing an older branch.
vim.cmd.enew()
local function edit(text)
  vim.cmd("normal! i\007u\027gg0C" .. text .. "\027")
  return vim.fn.undotree().seq_cur
end
local base = edit("base")
local left = edit("left")
local left_tip = edit("left tip")
vim.cmd("silent undo " .. base)
local right = edit("right")
local right_tip = edit("right tip")
vim.cmd("silent undo " .. left)
local nested = edit("nested")
local nested_tip = edit("nested tip")
vim.cmd("silent undo " .. left)
local newest = edit("newest")
local actual = graph.new(vim.fn.undotree())("")
local parents = {}
for _, item in ipairs(actual) do
  parents[item.seq] = item.parent
end
eq(parents[left], base)
eq(parents[right], base)
eq(parents[left_tip], left)
eq(parents[right_tip], right)
eq(parents[nested], left)
eq(parents[nested_tip], nested)
eq(parents[newest], left)
assert(actual[1].seq == newest and actual[1].current, "The most recently edited subtree should appear first")
print("PASS undo graph: real nested undo branches, sibling ancestry and recent edits on an older branch")
vim.cmd("qa!")
