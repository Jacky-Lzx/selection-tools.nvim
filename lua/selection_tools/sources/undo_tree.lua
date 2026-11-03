local M = {}

-- An alt list is a sibling of its containing entry: both start from the
-- previous entry, rather than the alt list branching from the containing one.
function M.new(tree)
  local nodes, roots, branches = {}, {}, 1
  local function collect(entries, parent, branch)
    for _, entry in ipairs(entries or {}) do
      if not nodes[entry.seq] then
        nodes[entry.seq] = {
          key = entry.seq,
          seq = entry.seq,
          parent = parent,
          branch = branch,
          time = entry.time,
          current = entry.seq == tree.seq_cur,
          saved = entry.save ~= nil and entry.save == tree.save_last,
          children = {},
        }
      end
      if entry.alt and #entry.alt > 0 then
        branches = branches + 1
        collect(entry.alt, parent, branches)
      end
      parent = entry.seq
    end
  end
  collect(tree.entries, nil, 1)
  local initial = nodes[1] ~= nil or next(nodes) == nil
  if initial then
    nodes[0] = { key = 0, seq = 0, current = tree.seq_cur == 0, children = {} }
  end
  for seq, node in pairs(nodes) do
    if seq ~= 0 and not node.parent and initial then
      node.parent = 0
    end
    local parent = node.parent and nodes[node.parent]
    local siblings = parent and parent.children or roots
    siblings[#siblings + 1] = seq
  end
  -- Keep sibling subtrees together so graph edges never cross unrelated lanes.
  -- Postorder puts descendants before their ancestors, with newer siblings first.
  local function walk(less, visit)
    local stack = {}
    table.sort(roots, less)
    for _, seq in ipairs(roots) do
      stack[#stack + 1] = { seq }
    end
    while #stack > 0 do
      local frame = table.remove(stack)
      local node = nodes[frame[1]]
      if frame[2] then
        visit(node)
      else
        stack[#stack + 1] = { node.seq, true }
        table.sort(node.children, less)
        for _, seq in ipairs(node.children) do
          stack[#stack + 1] = { seq }
        end
      end
    end
  end
  walk(nil, function(node)
    node.latest = node.seq
    for _, child in ipairs(node.children) do
      node.latest = math.max(node.latest, nodes[child].latest)
    end
  end)
  local ordered = {}
  walk(function(a, b)
    return nodes[a].latest < nodes[b].latest
  end, function(node)
    ordered[#ordered + 1] = node
  end)
  for _, node in ipairs(ordered) do
    node.timestamp = node.time and os.date("%Y-%m-%d %H:%M:%S", node.time) or "initial state"
    node.label = node.timestamp .. string.rep(" ", 21 - #node.timestamp)
    node.state_start = #node.label
    node.label = node.label .. (node.current and "current" or "       ") .. (node.saved and "  saved" or "")
    node.sequence = "#" .. node.seq
    node.sequence_start = #node.label + 2
    node.label = node.label .. "  " .. node.sequence
  end

  return function(query)
    query = query or ""
    local included, positions = {}, {}
    if query and query ~= "" then
      local sequence = query:match("^#(%d+)$")
      local candidate = sequence and nodes[tonumber(sequence)]
      local candidates = sequence and (candidate and { candidate } or {}) or ordered
      local matches = vim.fn.matchfuzzypos(candidates, query, { key = "label", matchseq = 1 })
      for i, node in ipairs(matches[1]) do
        positions[node.seq] = matches[2][i]
        while node and not included[node.seq] do
          included[node.seq] = true
          node = node.parent and nodes[node.parent]
        end
      end
    else
      for _, node in ipairs(ordered) do
        included[node.seq] = true
      end
    end
    local items, lanes = {}, {}
    for _, node in ipairs(ordered) do
      if included[node.seq] then
        local item = vim.tbl_extend("force", {}, node, { context = query ~= "" and positions[node.seq] == nil })
        local lane = vim.fn.index(lanes, node.seq) + 1
        if lane == 0 then
          lanes[#lanes + 1] = node.seq
          lane = #lanes
        end
        local cells = {}
        for i = 1, #lanes do
          cells[2 * i - 1], cells[2 * i] = "│", " "
        end
        cells[2 * lane - 1] = node.current and "◆" or "●"
        local parent_lane = node.parent and (vim.fn.index(lanes, node.parent) + 1) or 0
        if parent_lane > 0 then
          cells[2 * parent_lane - 1] = "├"
          for i = 2 * parent_lane, 2 * lane - 2 do
            cells[i] = "─"
          end
          table.remove(lanes, lane)
        elseif node.parent then
          lanes[lane] = node.parent
        else
          table.remove(lanes, lane)
        end
        item.cells, item.lane, item.parent_lane = cells, lane, parent_lane
        items[#items + 1] = item
      end
    end
    local bends = {}
    for i, item in ipairs(items) do
      local parent = items[i + 1]
      if item.parent_lane > 0 and parent and parent.seq == item.parent then
        -- Route an adjacent fork on the parent's row, reaching down/up to
        -- the child node, rather than putting a junction beside that child.
        item.cells[2 * item.parent_lane - 1] = "│"
        for cell = 2 * item.parent_lane, 2 * item.lane - 2 do
          item.cells[cell] = " "
        end
        bends[#bends + 1] = { parent = parent, lane = item.lane }
      end
    end
    for _, bend in ipairs(bends) do
      local parent = bend.parent
      for cell = #parent.cells + 1, 2 * bend.lane do
        parent.cells[cell] = " "
      end
      for cell = 2 * parent.lane, 2 * bend.lane - 2 do
        parent.cells[cell] = "─"
      end
      parent.cells[2 * bend.lane - 1] = "╯"
    end
    local width = 0
    for _, item in ipairs(items) do
      item.node_byte = #table.concat(item.cells, "", 1, 2 * item.lane - 2)
      item.graph = table.concat(item.cells)
      item.cells = nil
      width = math.max(width, vim.fn.strdisplaywidth(item.graph))
    end
    for _, item in ipairs(items) do
      local prefix = item.graph .. string.rep(" ", width - vim.fn.strdisplaywidth(item.graph))
      local body = item.label:sub(1, item.sequence_start) .. (item.context and "context  " or "")
      item.text = prefix .. body .. item.sequence
      local label = #prefix
      item.sequence_start = label + #body
      item.highlights = {
        { 0, label, hl = "Comment" },
        { item.node_byte, item.node_byte + #"●", hl = item.current and "DiagnosticOk" or "Special" },
        { label, label + #item.timestamp, hl = item.context and "Comment" or "Number" },
        { label + item.state_start, label + item.state_start + #"current", hl = "DiagnosticOk" },
        { item.sequence_start, #item.text, hl = "Comment" },
      }
      if item.saved then
        local first = label + item.label:find("saved", 1, true) - 1
        item.highlights[#item.highlights + 1] = { first, first + #"saved", hl = "DiagnosticInfo" }
      end
      if item.context then
        item.highlights[#item.highlights + 1] =
          { item.sequence_start - #"context  ", item.sequence_start, hl = "Comment" }
      end
      for _, pos in ipairs(positions[item.seq] or {}) do
        local first, last = vim.fn.byteidx(item.label, pos), vim.fn.byteidx(item.label, pos + 1)
        item.highlights[#item.highlights + 1] = {
          label + first,
          label + last,
          hl = "SelectionToolsMatch",
          priority = 120,
        }
      end
    end
    return items
  end
end

return M
