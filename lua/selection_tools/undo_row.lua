local M = {}

-- Clip at composed-character boundaries; offsets returned here remain byte
-- offsets for the picker's source-to-display highlight mapping.
local function keep(text, cells)
  local lo, hi, best = 0, vim.fn.strchars(text, true), ""
  while lo <= hi do
    local n = math.floor((lo + hi) / 2)
    local part = vim.fn.strcharpart(text, 0, n, true)
    if vim.fn.strdisplaywidth(part) <= cells then
      best, lo = part, n + 1
    else
      hi = n - 1
    end
  end
  return best
end

function M.render(entry, cells, prefix, reverse)
  local item, text = entry.item, entry.text
  if reverse then
    text = text:gsub("╯", "╮")
  end
  local sequence = text:sub(item.sequence_start + 1)
  local available = math.max(0, cells - vim.fn.strdisplaywidth(prefix))
  if vim.fn.strdisplaywidth(sequence) > available then
    sequence = keep(sequence, available)
  end
  local room = math.max(0, available - vim.fn.strdisplaywidth(sequence) - 1)
  local head = keep(text:sub(1, item.sequence_start):gsub("%s+$", ""), room)
  local line = prefix .. head
  local gap = math.max(0, cells - vim.fn.strdisplaywidth(line) - vim.fn.strdisplaywidth(sequence))
  local start = #line + gap
  return {
    text = line .. string.rep(" ", gap) .. sequence,
    segments = { { 0, #head, #prefix }, { item.sequence_start, item.sequence_start + #sequence, start } },
  }
end

return M
