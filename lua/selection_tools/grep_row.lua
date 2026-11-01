local M = {}
local fn = vim.fn

local function clean(text)
  return text:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "  "):gsub("%z", "\\0")
end
-- Tabs/control bytes are escaped first; strwidth avoids window-wrap padding.
local function width(text)
  return fn.strwidth(text)
end
local function ellipsis(cells)
  if cells <= 0 then
    return ""
  end
  return width("…") <= cells and "…" or "."
end
-- Binary search composed-character boundaries; never split a UTF-8 character
-- or its combining marks, and measure terminal cells rather than byte length.
local function keep(text, cells, tail)
  local total = fn.strchars(text, true)
  local lo, hi, best = 0, total, ""
  while lo <= hi do
    local n = math.floor((lo + hi) / 2)
    local part = fn.strcharpart(text, tail and total - n or 0, n, true)
    if width(part) <= cells then
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
local function tail(text, cells)
  if width(text) <= cells then
    return text
  end
  local mark = ellipsis(cells)
  return mark .. keep(text, math.max(0, cells - width(mark)), true)
end
function M.info(entry)
  if not entry.grep_info or entry.grep_info.ambiwidth ~= vim.o.ambiwidth then
    local item = entry.item
    local code = clean(item.display_code or item.code)
    local file = clean(item.display_file or vim.fn.fnamemodify(item.file, ":~:."))
    local position = ("%d:%d"):format(item.pos[1], item.pos[2] + 1)
    entry.grep_info = {
      code = code,
      ambiwidth = vim.o.ambiwidth,
      offset = #entry.text - #code,
      file = file,
      position = position,
      file_width = width(file),
      position_width = width(position),
      width = width(file) + 2 + width(position),
    }
  end
  return entry.grep_info
end
function M.file_width(cells, wanted)
  if cells < 18 then
    return 0
  end
  local minimum_code = cells >= 28 and 16 or 8
  return math.min(wanted, math.max(8, math.min(math.floor(cells * 0.4), cells - 2 - minimum_code)))
end
local function snippet(code, cells, focus, focus_end, preserve_indent)
  local start = preserve_indent and 0 or #(code:match("^%s*") or "")
  if focus then
    start = math.min(start, boundary(code, focus))
  end
  local base, leading = start, ""
  local first = keep(code:sub(start + 1), math.max(0, cells - width(ellipsis(cells))), false)
  if focus and width(code:sub(start + 1)) > cells and (focus_end or focus) > start + #first and focus > start then
    local before = code:sub(start + 1, boundary(code, focus))
    local room = math.max(0, cells - 2 * width(ellipsis(cells)))
    local hit_width = width(code:sub(focus + 1, focus_end or focus))
    local context = keep(before, math.min(math.floor(room / 3), math.max(0, room - hit_width)), true)
    start = boundary(code, start + #before - #context)
    if start > base then
      leading = ellipsis(cells)
    end
  end
  local remaining = math.max(0, cells - width(leading))
  local rest, trailing = code:sub(start + 1), ""
  if width(rest) > remaining then
    trailing = ellipsis(remaining)
  end
  local body = keep(rest, math.max(0, remaining - width(trailing)), false)
  return leading .. body .. trailing, start, start + #body, #leading
end
function M.render(entry, cells, file_cells, mark, icon, matches, icon_width, position_width)
  local info = M.info(entry)
  local focus, focus_end
  for _, range in ipairs(matches) do
    if range[2] > info.offset then
      focus = math.max(0, range[1] - info.offset)
      focus_end = math.min(#info.code, range[2] - info.offset)
      break
    end
  end
  icon_width = icon_width or (icon and width(icon.text) or 0)
  position_width = math.max(position_width or 0, info.position_width)
  local key = cells
    .. ":"
    .. file_cells
    .. ":"
    .. mark
    .. ":"
    .. (icon and icon.text or "")
    .. ":"
    .. icon_width
    .. ":"
    .. vim.o.ambiwidth
    .. ":"
    .. (focus or "")
    .. ":"
    .. (focus_end or "")
    .. ":"
    .. position_width
  if entry.grep_render_key == key then
    return entry.grep_render
  end
  local available = math.max(0, cells - width(mark))
  local gap = file_cells > 0 and 2 or 0
  local code_cells = math.max(0, available - gap - file_cells)
  local code, first, last, leading = snippet(info.code, code_cells, focus, focus_end, entry.item.display_indent)
  local result = { text = mark .. code, segments = { { info.offset + first, info.offset + last, #mark + leading } } }
  if file_cells > 0 then
    local glyph = icon and icon.text or ""
    local icon_cells = file_cells >= 10 and icon_width > 0 and icon_width + 1 or 0
    if file_cells - icon_cells < 4 then
      icon_cells = 0
    end
    local path_cells = file_cells - icon_cells
    local show_position = path_cells >= position_width + 2 + 4
    if show_position then
      path_cells = path_cells - position_width - 2
    end
    local name = tail(info.file, path_cells)
    local pad = code_cells - width(code) + gap + path_cells - width(name)
    result.text = result.text .. string.rep(" ", math.max(0, pad))
    result.filename = { #result.text, #result.text + #name }
    result.text = result.text .. name
    if show_position then
      result.text = result.text .. "  "
      local first = #result.text
      result.text = result.text .. string.rep(" ", position_width - info.position_width) .. info.position
      result.position = { first, #result.text }
    end
    result.file = { result.filename[1], #result.text }
    if icon_cells > 0 then
      result.text = result.text .. " "
      if glyph ~= "" then
        result.icon = { first = #result.text, last = #result.text + #glyph, hl = icon.hl }
      end
      result.text = result.text .. glyph .. string.rep(" ", icon_width - width(glyph))
    end
  end
  entry.grep_render_key, entry.grep_render = key, result
  return result
end
return M
