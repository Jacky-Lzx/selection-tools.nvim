local text = require("selection_tools.component_text")
local Row = {}
Row.__index = Row

local defaults = {
  text = { field = "text", searchable = true, hl = "SelectionToolsText", min_width = 1, priority = 100 },
  path = {
    field = "file",
    searchable = true,
    hl = "SelectionToolsPath",
    path_format = ":~:.",
    truncate = "left",
    min_width = 4,
    grow = 1,
    priority = 80,
  },
  position = { field = "pos", searchable = true, hl = "SelectionToolsPosition", min_width = 3, priority = 50 },
  time = {
    field = "timestamp",
    searchable = false,
    hl = "SelectionToolsTime",
    format = "%Y-%m-%d %H:%M:%S",
    min_width = 4,
    priority = 40,
  },
  icon = { searchable = false, min_width = 1, priority = 10 },
}

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Row.new(opts)
  assert(type(opts.components) == "table" and vim.islist(opts.components), "selection-tools: components must be a list")
  assert(type(opts.component_defaults or {}) == "table", "selection-tools: component_defaults must be a table")
  local self = setmetatable(
    { specs = {}, order = {}, row_cache = {}, automatic_icon = false, match_text = opts.match_text, search_count = 0 },
    Row
  )
  assert(
    opts.match_text == nil or type(opts.match_text) == "function",
    "selection-tools: match_text must be a function"
  )
  for _, value in ipairs(opts.components) do
    assert(type(value) == "table" and defaults[value.kind], "selection-tools: unknown component kind")
    local spec = vim.tbl_extend(
      "force",
      { grow = 0, align = "left", truncate = "right" },
      defaults[value.kind],
      opts.component_defaults and opts.component_defaults[value.kind] or {},
      value
    )
    for _, name in ipairs({ "get", "highlights" }) do
      assert(
        spec[name] == nil or type(spec[name]) == "function",
        "selection-tools: component " .. name .. " must be a function"
      )
    end
    assert(spec.field == nil or type(spec.field) == "string", "selection-tools: component field must be a string")
    assert(
      spec.hl == nil or spec.hl == false or type(spec.hl) == "string",
      "selection-tools: component hl must be a string or false"
    )
    assert(type(spec.searchable) == "boolean", "selection-tools: component searchable must be boolean")
    assert(spec.kind ~= "icon" or not spec.searchable, "selection-tools: icons cannot be searchable")
    assert(
      spec.kind ~= "icon" or not spec.get and not spec.field,
      "selection-tools: use format_icon to customize icon values"
    )
    for _, name in ipairs({ "width", "min_width", "max_width" }) do
      local n = spec[name]
      assert(
        n == nil or finite(n) and n >= 0 and n % 1 == 0,
        "selection-tools: component " .. name .. " must be a nonnegative integer"
      )
    end
    assert(
      not spec.max_width or spec.max_width >= spec.min_width,
      "selection-tools: component max_width is below min_width"
    )
    assert(finite(spec.grow) and spec.grow >= 0, "selection-tools: component grow must be nonnegative")
    assert(finite(spec.priority), "selection-tools: component priority must be finite")
    assert(spec.align == "left" or spec.align == "right", "selection-tools: invalid component alignment")
    assert(
      vim.tbl_contains({ "left", "right", "match" }, spec.truncate),
      "selection-tools: invalid component truncation"
    )
    assert(spec.kind ~= "time" or type(spec.format) == "string", "selection-tools: time format must be a string")
    assert(
      spec.kind ~= "path" or spec.path_format == false or type(spec.path_format) == "string",
      "selection-tools: path_format must be a string or false"
    )
    self.specs[#self.specs + 1] = spec
    if spec.searchable then
      self.search_count, self.search_index = self.search_count + 1, #self.specs
    end
    self.automatic_icon = self.automatic_icon or spec.kind == "icon" and not spec.get and not spec.field
    self.syntax_code = self.syntax_code or spec.field == "code" and not spec.get
    self.needs_focus = self.needs_focus or spec.truncate == "match"
    self.order[#self.order + 1] = #self.specs
  end
  table.sort(self.order, function(a, b)
    if self.specs[a].priority == self.specs[b].priority then
      return a > b
    end
    return self.specs[a].priority < self.specs[b].priority
  end)
  return self
end

local function value(spec, item, index)
  local result
  if spec.get then
    result = spec.get(item, index)
  elseif type(item) == "table" then
    result = item[spec.field]
  elseif spec.kind == "text" then
    result = item
  end
  if result == nil then
    return ""
  end
  if spec.kind == "path" and spec.path_format then
    result = vim.fn.fnamemodify(tostring(result), spec.path_format)
  elseif spec.kind == "position" then
    assert(
      type(result) == "table" and type(result[1]) == "number",
      "selection-tools: position expects { row, zero_based_column }"
    )
    result = ("%d:%d"):format(result[1], (result[2] or 0) + 1)
  elseif spec.kind == "time" and type(result) == "number" then
    result = os.date(spec.format, result)
  end
  return tostring(result)
end

-- Only searchable values are evaluated for the full candidate set. No layout
-- objects or widths are allocated until an entry becomes visible.
function Row:entry(item, index)
  local values = self.search_count > 1 and not self.match_text and {} or nil
  local parts = values and {} or nil
  local single
  for i, spec in ipairs(self.specs) do
    if spec.searchable and not self.match_text then
      local raw = value(spec, item, index)
      if values then
        values[i] = raw
      else
        single = raw
      end
      if parts and raw ~= "" then
        parts[#parts + 1] = raw
      end
    end
  end
  local raw
  if self.match_text then
    local result = self.match_text(item, index)
    raw = result == nil and "" or tostring(result)
  else
    raw = single or (parts and table.concat(parts, " ")) or ""
  end
  local clean = text.clean(raw)
  local entry = {
    item = item,
    index = index,
    text = clean,
    raw_text = raw ~= clean and raw or nil,
  }
  if values then
    entry.component_values = values
  end
  return entry
end

function Row:prepare(entry, icon)
  if entry.component_chunks and entry.component_ambiwidth == vim.o.ambiwidth then
    -- Icon providers can change independently of candidate replacement.
    if entry.component_icon == icon then
      return entry.component_chunks
    end
  end
  local chunks, source = {}, 0
  if type(entry.component_values) ~= "table" then
    entry.component_values = {}
    if self.search_count == 1 and not self.match_text then
      entry.component_values[self.search_index] = entry.raw_text or entry.text
    end
  end
  for i, spec in ipairs(self.specs) do
    local automatic = spec.kind == "icon" and not spec.get and not spec.field
    local raw = automatic and (icon and icon.text or "") or entry.component_values[i]
    if raw == nil then
      local ok, result = pcall(value, spec, entry.item, entry.index)
      raw = ok and result or ""
      if not ok and not self.value_warned then
        self.value_warned = true
        vim.notify("selection-tools: component formatter failed: " .. tostring(result), vim.log.levels.WARN)
      end
      entry.component_values[i] = raw
    end
    local clean = text.clean(raw)
    local first
    if spec.searchable and raw ~= "" and not self.match_text then
      if source > 0 then
        source = source + 1
      end
      first, source = source, source + #clean
    end
    local hl = spec.hl
    if hl == nil and automatic and icon then
      hl = icon.hl
    end
    chunks[i] = {
      text = clean,
      raw = raw,
      width = vim.fn.strwidth(clean),
      first = first,
      hl = hl,
    }
  end
  entry.component_chunks, entry.component_icon, entry.component_ambiwidth = chunks, icon, vim.o.ambiwidth
  return chunks
end

-- Measure visible rows only. Shrink lower-priority columns first, then omit
-- them if their minimum widths cannot fit. Empty columns consume no gap.
function Row:widths(entries, cells)
  local wanted, same = {}, self.width_cache and self.width_cache.cells == cells
  for i, spec in ipairs(self.specs) do
    local value = 0
    for _, chunks in pairs(entries) do
      value = math.max(value, chunks[i].width)
    end
    wanted[i] = value
    same = same and self.width_cache.wanted[i] == value
  end
  if same then
    return self.width_cache.widths
  end
  local widths, minimum = {}, {}
  for i, spec in ipairs(self.specs) do
    widths[i] = wanted[i] > 0 and math.min(spec.width or wanted[i], spec.max_width or math.huge) or 0
    minimum[i] = math.min(widths[i], spec.min_width)
    if spec.kind == "icon" then
      minimum[i] = widths[i]
    end
  end
  local function total()
    local sum, count = 0, 0
    for _, width in ipairs(widths) do
      if width > 0 then
        sum, count = sum + width, count + 1
      end
    end
    return sum + math.max(0, count - 1)
  end
  local used = total()
  for _, i in ipairs(self.order) do
    local remove = math.min(math.max(0, used - cells), widths[i] - minimum[i])
    widths[i] = widths[i] - remove
    used = total()
  end
  for _, i in ipairs(self.order) do
    if used <= cells then
      break
    end
    widths[i] = 0
    used = total()
  end
  -- Weighted growth uses only existing columns, respecting their upper bounds.
  while used < cells do
    local weight = 0
    for i, spec in ipairs(self.specs) do
      if widths[i] > 0 and widths[i] < (spec.max_width or math.huge) then
        weight = weight + spec.grow
      end
    end
    if weight == 0 then
      break
    end
    local room, added = cells - used, 0
    for i, spec in ipairs(self.specs) do
      if widths[i] > 0 and spec.grow > 0 then
        local extra = math.min(
          room - added,
          spec.max_width and spec.max_width - widths[i] or room,
          math.max(1, math.floor(room * spec.grow / weight))
        )
        widths[i], added = widths[i] + extra, added + extra
      end
    end
    used = used + added
    if added == 0 then
      break
    end
  end
  self.width_cache = { cells = cells, wanted = wanted, widths = widths }
  return widths
end

-- Retain composed rows for the current viewport only, rather than every entry
-- visited while browsing a large candidate set.
function Row:retain(indices, matches)
  local visible = {}
  for _, index in pairs(indices) do
    local entry = matches[index]
    visible[entry] = self.row_cache[entry]
  end
  self.row_cache = visible
end

local function ranges(chunk, spec, entry, row)
  if chunk.highlights then
    return chunk.highlights
  end
  local ok, result = true, {}
  if spec.highlights then
    ok, result = pcall(spec.highlights, entry.item, entry.index)
  end
  chunk.highlights = {}
  if ok and type(result) == "table" then
    for _, range in ipairs(result) do
      if type(range) == "table" and finite(range[1]) and finite(range[2]) then
        chunk.highlights[#chunk.highlights + 1] = range
      end
    end
  elseif not ok and not row.highlight_warned then
    row.highlight_warned = true
    vim.notify("selection-tools: component highlighter failed: " .. tostring(result), vim.log.levels.WARN)
  end
  return chunk.highlights
end

function Row:render(entry, widths, prefix, focus, syntax)
  syntax = self.syntax_code and syntax or nil
  local cached = self.row_cache[entry]
  if
    cached
    and cached.chunks == entry.component_chunks
    and cached.widths == widths
    and cached.prefix == prefix
    and cached.focus == focus
    and cached.syntax == syntax
  then
    return cached.result
  end
  local result = { text = prefix, segments = {}, highlights = {} }
  local chunks, present, padding = entry.component_chunks, false, ""
  local function span(first, last, hl, priority)
    if hl and first < last then
      result.highlights[#result.highlights + 1] = { first, last, hl = hl, priority = priority or 100 }
    end
  end
  for i, spec in ipairs(self.specs) do
    local chunk, cells = chunks[i], widths[i]
    if chunk.width > 0 and cells > 0 then
      if present then
        result.text = result.text .. padding .. " "
      end
      present = true
      local hit
      for _, range in ipairs(focus) do
        if chunk.first and range[1] < chunk.first + #chunk.text and range[2] > chunk.first then
          local a, b = math.max(0, range[1] - chunk.first), math.min(#chunk.text, range[2] - chunk.first)
          if not hit then
            hit = { a, b }
          elseif a <= hit[2] then
            hit[2] = math.max(hit[2], b)
          else
            break
          end
        end
      end
      local label, first, last, leading, label_width = chunk.text, 0, #chunk.text, 0, chunk.width
      if chunk.width > cells then
        label, first, last, leading = text.clip(chunk.text, cells, spec.truncate, hit)
        label_width = vim.fn.strwidth(label)
      end
      local pad = math.max(0, cells - label_width)
      if spec.align == "right" then
        result.text = result.text .. string.rep(" ", pad)
      end
      local start = #result.text
      result.text = result.text .. label
      span(start, #result.text, chunk.hl)
      if chunk.first then
        result.segments[#result.segments + 1] = { chunk.first + first, chunk.first + last, start + leading }
      end
      local function local_span(range)
        local a = math.max(first, text.offset(chunk.raw, math.max(0, math.min(#chunk.raw, math.floor(range[1])))))
        local b = math.min(last, text.offset(chunk.raw, math.max(0, math.min(#chunk.raw, math.floor(range[2])))))
        span(
          start + leading + a - first,
          start + leading + b - first,
          range.hl or "SelectionToolsMatch",
          range.priority or (range.hl and range.hl ~= "SelectionToolsMatch" and 100 or 110)
        )
      end
      for _, range in ipairs(ranges(chunk, spec, entry, self)) do
        local_span(range)
      end
      -- Tree-sitter spans are local to the original code, independent of the
      -- search document (the code component may be display-only).
      if not spec.get and spec.field == "code" and type(entry.item) == "table" and chunk.raw == entry.item.code then
        for _, range in ipairs(syntax or {}) do
          local_span(range)
        end
      end
      padding = spec.align == "left" and string.rep(" ", pad) or ""
    end
  end
  self.row_cache[entry] =
    { chunks = chunks, widths = widths, prefix = prefix, focus = focus, syntax = syntax, result = result }
  return result
end

return Row
