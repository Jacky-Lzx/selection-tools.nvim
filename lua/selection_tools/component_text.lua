local M = {}
local fn = vim.fn

function M.clean(value)
  return tostring(value):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "  "):gsub("%z", "\\0")
end

-- A raw byte boundary advances by one extra byte for each escaped control.
function M.offset(raw, byte)
  local _, count = raw:sub(1, byte):gsub("[\r\n\t%z]", "")
  return byte + count
end

local function keep(text, cells, tail)
  local count = fn.strchars(text, true)
  local lo, hi, best = 0, count, ""
  while lo <= hi do
    local n = math.floor((lo + hi) / 2)
    local part = fn.strcharpart(text, tail and count - n or 0, n, true)
    if fn.strwidth(part) <= cells then
      best, lo = part, n + 1
    else
      hi = n - 1
    end
  end
  return best
end

local function boundary(text, byte)
  local lo, hi, best = 0, fn.strchars(text, true), 0
  while lo <= hi do
    local n = math.floor((lo + hi) / 2)
    local length = #fn.strcharpart(text, 0, n, true)
    if length <= byte then
      best, lo = length, n + 1
    else
      hi = n - 1
    end
  end
  return best
end

-- Return the retained source interval and its byte offset in the clipped label.
function M.clip(text, cells, mode, focus)
  if fn.strwidth(text) <= cells then
    return text, 0, #text, 0
  end
  if cells <= 0 then
    return "", 0, 0, 0
  end
  local mark = fn.strwidth("…") <= cells and "…" or "."
  local room = math.max(0, cells - fn.strwidth(mark))
  if mode == "left" then
    local part = keep(text, room, true)
    return mark .. part, #text - #part, #text, #mark
  end
  if mode == "match" and focus then
    local head = keep(text, room, false)
    if focus[2] > #head then
      -- Keep some preceding context without splitting composed characters.
      local before = text:sub(1, boundary(text, focus[1]))
      local budget = math.max(0, room - fn.strwidth(mark))
      local hit_width = fn.strwidth(text:sub(focus[1] + 1, focus[2]))
      local context = keep(before, math.min(math.floor(budget / 3), math.max(0, budget - hit_width)), true)
      local start = #before - #context
      local rest = text:sub(start + 1)
      local trailing = fn.strwidth(rest) > room and mark or ""
      local part = keep(rest, math.max(0, room - fn.strwidth(trailing)), false)
      return mark .. part .. trailing, start, start + #part, #mark
    end
  end
  local part = keep(text, room, false)
  return part .. mark, 0, #part, 0
end

return M
