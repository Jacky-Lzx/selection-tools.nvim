local api = vim.api
local ns = api.nvim_create_namespace("selection_tools")
local active

---@class selection_tools.Picker
---@field input_buf integer
---@field list_buf integer
---@field input_win integer
---@field list_win integer
---@field closed boolean
---@field query string
---@field loading boolean
---@field entries table[]
---@field matches table[]
local Picker = {}
Picker.__index = Picker

local function notify(err)
  vim.notify("selection-tools: " .. tostring(err), vim.log.levels.ERROR)
end

local function single_line(value)
  return tostring(value):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "  "):gsub("%z", "\\0")
end

function Picker:_layout()
  self.resolved = require("selection_tools.layout").resolve(self.opts)
  self.height = self.resolved.height
  return self.resolved
end

function Picker:_draw_frame()
  if not self.frame_buf or not api.nvim_buf_is_valid(self.frame_buf) then
    return
  end
  if self.opts.search_options then
    local title = single_line(self.opts.prompt or "Select")
      .. require("selection_tools.search_options").label(self.opts)
    api.nvim_win_set_config(self.frame_win, { title = " " .. single_line(title) .. " " })
  end
  local lines = {}
  for i = 1, self.resolved.total_height do
    lines[i] = ""
  end
  for _, row in ipairs(self.resolved.separators) do
    lines[row + 1] = string.rep("─", self.resolved.width)
  end
  vim.bo[self.frame_buf].modifiable = true
  api.nvim_buf_set_lines(self.frame_buf, 0, -1, false, lines)
  vim.bo[self.frame_buf].modifiable = false
  api.nvim_buf_clear_namespace(self.frame_buf, ns, 0, -1)
  for _, row in ipairs(self.resolved.separators) do
    api.nvim_buf_set_extmark(self.frame_buf, ns, row, 0, { line_hl_group = "SelectionToolsBorder" })
  end
  self:_draw_separators()
  local marked = vim.tbl_count(self.marks)
  local status = self.error and "Error" or (self.loading and "Loading" or (self.matching and "Matching" or nil))
  local current = self.matches[self.index] and self.index or 0
  local count = (" %d/%d%s%s "):format(
    current,
    #self.matches,
    status and (" · " .. status) or "",
    marked > 0 and (" · " .. marked .. " selected") or ""
  )
  count = vim.fn.strcharpart(count, 0, self.resolved.width - 1)
  local input_width = self.resolved.width - vim.fn.strdisplaywidth(count)
  if api.nvim_win_get_width(self.input_win) ~= input_width then
    api.nvim_win_set_config(self.input_win, { width = input_width })
  end
  local input_row = self.opts.layout.input_position == "bottom" and self.resolved.total_height - 1 or 0
  api.nvim_buf_set_extmark(self.frame_buf, ns, input_row, 0, {
    virt_text = { { count, "SelectionToolsCount" } },
    virt_text_pos = "right_align",
  })
end

local function scratch(filetype)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  -- Completion plugins must not replace picker navigation or confirmation keys.
  vim.b[buf].completion = false
  vim.bo[buf].filetype = filetype
  vim.bo[buf].swapfile = false
  return buf
end

function Picker:_draw_separators()
  -- Native float borders cannot change their side character on individual rows.
  -- Overlay each divider across the sides as well, so the tee joints are continuous.
  local border = api.nvim_win_get_config(self.frame_win).border or {}
  local function char(index)
    local value = border[index]
    return type(value) == "table" and value[1] or (value or "")
  end
  local left, right = char(8), char(4)
  local joints = { ["│"] = { "├", "┤" }, ["║"] = { "╠", "╣" }, ["┃"] = { "┣", "┫" } }
  local horizontal = (left == "║" or right == "║") and "═"
    or ((left == "┃" or right == "┃") and "━" or "─")
  local line = (joints[left] and joints[left][1] or left)
    .. string.rep(horizontal, self.resolved.width)
    .. (joints[right] and joints[right][2] or right)
  if not self.separator_buf or not api.nvim_buf_is_valid(self.separator_buf) then
    self.separator_buf = scratch("selection_tools_separator")
    self.separator_wins = {}
  end
  vim.bo[self.separator_buf].modifiable = true
  api.nvim_buf_set_lines(self.separator_buf, 0, -1, false, { line })
  vim.bo[self.separator_buf].modifiable = false
  api.nvim_buf_set_extmark(self.separator_buf, ns, 0, 0, { id = 1, line_hl_group = "SelectionToolsBorder" })
  for i, row in ipairs(self.resolved.separators) do
    local config = {
      relative = "editor",
      style = "minimal",
      border = "none",
      row = self.resolved.frame.row + row + (char(2) ~= "" and 1 or 0),
      col = self.resolved.frame.col,
      width = vim.fn.strdisplaywidth(line),
      height = 1,
      zindex = 62,
      focusable = false,
    }
    local win = self.separator_wins[i]
    if win and api.nvim_win_is_valid(win) then
      api.nvim_win_set_config(win, config)
    else
      win = api.nvim_open_win(self.separator_buf, false, config)
      self.separator_wins[i] = win
      vim.wo[win].wrap = false
      vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:SelectionToolsBorder"
    end
  end
  for i = #self.separator_wins, #self.resolved.separators + 1, -1 do
    local win = table.remove(self.separator_wins, i)
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
end

function Picker:_set_items(items)
  assert(type(items) == "table", "finder results must be a list")
  local entries = {}
  for index, item in ipairs(items) do
    local text = self.opts.format_item and self.opts.format_item(item) or tostring(item)
    local raw = tostring(text)
    local display = single_line(raw)
    entries[index] = {
      item = item,
      index = index,
      text = display,
      raw_text = (self.opts.highlight_item or self.opts.syntax.enabled) and raw ~= display and raw or nil,
    }
  end
  self.entries, self.marks = entries, {}
  self.matcher:set_entries(entries)
  if self.list_buf then
    self:_filter()
  else
    self.matches = entries
  end
end

function Picker:_filter()
  if self.closed then
    return
  end
  self.positions = {}
  self.index, self.offset = 1, 0
  if self.query == "" or self.opts.match == false or #self.entries == 0 then
    self.matcher:cancel()
    self.matching, self.match_backend = false, "none"
    self.matches = self.entries
    self:_render()
    return
  end
  local backend = self.matcher:select(self.query)
  self.matching, self.match_backend = backend == "skim", backend
  if self.matching then
    self.matches = {}
    self:_render()
  end
  self.matcher:run(self.query, backend, function(matches, positions, used)
    if self.closed then
      return
    end
    self.matching, self.match_backend = false, used
    self.matches, self.positions, self.index, self.offset = matches, positions, 1, 0
    self:_apply_restore()
    self:_render()
  end)
end

function Picker:_icon(entry)
  local config = self.opts.item_icons
  if config == false or (type(config) == "table" and config.enabled == false) then
    return
  end
  local item = entry.item
  if
    not self.opts.format_icon and not (type(item) == "table" and (item.file or item.dir or item.bufnr or item.buf))
  then
    return
  end
  if not self.icon_resolver then
    self.icon_resolver = require("selection_tools.item_icons").new(self.opts)
  end
  return self.icon_resolver(entry)
end

local function map_ranges(entry, ranges)
  local highlights = {}
  local raw = entry.raw_text or entry.text
  local boundaries = {}
  for _, range in ipairs(type(ranges) == "table" and ranges or {}) do
    if type(range) == "table" and type(range[1]) == "number" and type(range[2]) == "number" then
      local first = math.max(0, math.min(#raw, math.floor(range[1])))
      local last = math.max(0, math.min(#raw, math.floor(range[2])))
      if first < last then
        highlights[#highlights + 1] = { first, last, hl = range.hl, priority = range.priority }
        boundaries[first], boundaries[last] = first, last
      end
    end
  end
  if entry.raw_text then
    local offsets = vim.tbl_keys(boundaries)
    table.sort(offsets)
    local controls = raw:gmatch("()[\r\n\t%z]")
    local next_control, added = controls(), 0
    for _, offset in ipairs(offsets) do
      while next_control and next_control <= offset do
        added, next_control = added + 1, controls()
      end
      boundaries[offset] = offset + added
    end
    for _, range in ipairs(highlights) do
      range[1], range[2] = boundaries[range[1]], boundaries[range[2]]
    end
  end
  return highlights
end

-- Source ranges use zero-based byte offsets in the formatted label. Resolve only
-- visible entries and account for the renderer escaping tabs and control bytes.
function Picker:_highlights(entry)
  if entry.highlights then
    return entry.highlights
  end
  entry.highlights = {}
  if not self.opts.highlight_item then
    return entry.highlights
  end
  local ok, ranges = pcall(self.opts.highlight_item, entry.item, entry.index)
  if not ok then
    if not self.highlight_warned then
      self.highlight_warned = true
      vim.notify("selection-tools: item highlighter failed: " .. tostring(ranges), vim.log.levels.WARN)
    end
    return entry.highlights
  end
  entry.highlights = map_ranges(entry, ranges)
  return entry.highlights
end

function Picker:_syntax(entry)
  local item = entry.item
  if
    not self.opts.syntax.enabled
    or type(item) ~= "table"
    or not item.file
    or not item.pos
    or not item.code
    or not item.content_offset
  then
    return {}
  end
  if not self.syntax then
    self.syntax = require("selection_tools.syntax").new(self)
  end
  local spans = self.syntax:highlights(item)
  if not spans then
    return {}
  end
  if entry.syntax_source ~= spans then
    local ranges = {}
    for _, span in ipairs(spans) do
      ranges[#ranges + 1] =
        { item.content_offset + span[1], item.content_offset + span[2], hl = span.hl, priority = span.priority }
    end
    entry.syntax_source, entry.syntax_ranges = spans, map_ranges(entry, ranges)
  end
  return entry.syntax_ranges
end

function Picker:_render()
  if self.closed or not self.list_buf or not api.nvim_buf_is_valid(self.list_buf) then
    return
  end
  local count = #self.matches
  self.offset = math.max(0, math.min(self.offset, math.max(0, count - self.height)))
  if self.index <= self.offset then
    self.offset = self.index - 1
  elseif self.index > self.offset + self.height then
    self.offset = self.index - self.height
  end
  local lines = {}
  self.row_to_index = {}
  local reverse = self.opts.layout.reverse
  local mark_width = self.opts.multi and 1 or 0
  local icons, icon_width, rows = {}, 0, {}
  local columns = self.opts.result_layout == "grep" and require("selection_tools.grep_row") or nil
  local wanted_file = 0
  if reverse and count > 0 then
    for row = 1, self.height do
      lines[row] = ""
    end
  end
  for i = self.offset + 1, math.min(count, self.offset + self.height) do
    local row = reverse and (self.height - (i - self.offset) + 1) or (i - self.offset)
    local entry = self.matches[i]
    self.row_to_index[row] = i
    local icon = self:_icon(entry)
    if icon then
      icons[row] = icon
      icon_width = math.max(icon_width, vim.fn.strdisplaywidth(icon.text))
    end
    if columns then
      wanted_file = math.max(wanted_file, columns.info(entry).width)
    end
  end
  wanted_file = wanted_file + (icon_width > 0 and icon_width + 1 or 0)
  local file_cells = columns and columns.file_width(self.resolved.width - mark_width, wanted_file) or 0
  for row, index in pairs(self.row_to_index) do
    local entry = self.matches[index]
    local prefix = self.opts.multi and (self.marks[entry.index] and "*" or " ") or ""
    if columns then
      rows[row] =
        columns.render(entry, self.resolved.width, file_cells, prefix, icons[row], self:_highlights(entry), icon_width)
    else
      if icon_width > 0 then
        local glyph = icons[row] and icons[row].text or ""
        prefix = prefix .. glyph .. string.rep(" ", icon_width - vim.fn.strdisplaywidth(glyph) + 1)
      end
      rows[row] = {
        text = prefix .. entry.text,
        segments = { { 0, #entry.text, #prefix } },
        icon = icons[row] and { first = mark_width, last = mark_width + #icons[row].text, hl = icons[row].hl },
      }
    end
    lines[row] = rows[row].text
  end
  if count == 0 then
    lines[1] = self.error and ("Error: " .. single_line(self.error))
      or (self.loading and "Loading…" or (self.matching and "Matching…" or "No results"))
  end
  self.rendering = true
  vim.bo[self.list_buf].modifiable = true
  api.nvim_buf_set_lines(self.list_buf, 0, -1, false, lines)
  vim.bo[self.list_buf].modifiable = false
  api.nvim_buf_clear_namespace(self.list_buf, ns, 0, -1)
  if count > 0 then
    for row, index in pairs(self.row_to_index) do
      local display = rows[row]
      local function highlight(first, last, group, priority)
        for _, segment in ipairs(display.segments) do
          local start, finish = math.max(first, segment[1]), math.min(last, segment[2])
          if start < finish then
            api.nvim_buf_set_extmark(self.list_buf, ns, row - 1, segment[3] + start - segment[1], {
              end_col = segment[3] + finish - segment[1],
              hl_group = group,
              priority = priority,
            })
          end
        end
      end
      local icon = display.icon
      if icon then
        api.nvim_buf_set_extmark(self.list_buf, ns, row - 1, icon.first, {
          end_col = icon.last,
          hl_group = icon.hl,
          priority = 120,
        })
      end
      if display.file then
        api.nvim_buf_set_extmark(self.list_buf, ns, row - 1, display.file[1], {
          end_col = display.file[2],
          hl_group = "SelectionToolsFileLocation",
          priority = 100,
        })
      end
      if not self.positions[index] and self.match_backend == "skim" then
        -- Only visible rows need highlight positions from the native matcher.
        self.positions[index] = vim.fn.matchfuzzypos({ self.matches[index].text }, self.query, { matchseq = 1 })[2][1]
          or {}
      end
      for _, span in ipairs(self:_syntax(self.matches[index])) do
        highlight(span[1], span[2], span.hl, span.priority)
      end
      for _, range in ipairs(self:_highlights(self.matches[index])) do
        highlight(range[1], range[2], "SelectionToolsMatch", 110)
      end
      for _, pos in ipairs(self.positions[index] or {}) do
        highlight(
          vim.fn.byteidx(self.matches[index].text, pos),
          vim.fn.byteidx(self.matches[index].text, pos + 1),
          "SelectionToolsMatch",
          110
        )
      end
    end
    local row = reverse and (self.height - (self.index - self.offset) + 1) or (self.index - self.offset)
    -- A text range respects match priorities; line_hl_group can mask bg-only Search.
    api.nvim_buf_set_extmark(
      self.list_buf,
      ns,
      row - 1,
      0,
      { end_row = row, end_col = 0, hl_group = "SelectionToolsSelected", hl_eol = true, priority = 90 }
    )
    api.nvim_win_set_cursor(self.list_win, { row, 0 })
  else
    api.nvim_buf_set_extmark(self.list_buf, ns, 0, 0, { line_hl_group = "Comment" })
  end
  self.rendering = false
  self:_draw_frame()
  if self.preview and self.preview_win then
    self.preview:update(self:current())
    self:_restore_preview()
  end
end

function Picker:_cancel_finder()
  self.generation = self.generation + 1
  local cancel = self.cancel_finder
  self.cancel_finder = nil
  if cancel then
    local ok, err = pcall(cancel)
    if not ok then
      notify(err)
    end
  end
end

function Picker:_find()
  self:_cancel_finder()
  local generation = self.generation
  self.loading, self.error = true, nil
  self:_set_items({})
  local function current()
    return not self.closed and self.generation == generation
  end
  local ctx = {
    query = self.query,
    cwd = self.opts.cwd or vim.fn.getcwd(),
    opts = self.opts,
    is_cancelled = function()
      return not current()
    end,
  }
  -- Scheduled delivery makes these safe from vim.system/libuv callbacks.
  ctx.set_items = function(items)
    vim.schedule(function()
      if current() then
        local ok, err = pcall(self._set_items, self, items)
        if not ok then
          ctx.fail(err)
        end
      end
    end)
  end
  ctx.done = function()
    vim.schedule(function()
      if current() then
        self.loading = false
        self:_apply_restore()
        self:_render()
      end
    end)
  end
  ctx.fail = function(err)
    vim.schedule(function()
      if current() then
        self.loading, self.error = false, tostring(err)
        self:_render()
        notify(err)
      end
    end)
  end
  local ok, cancel = pcall(self.opts.finder, ctx)
  if not ok then
    ctx.fail(cancel)
  elseif type(cancel) == "function" then
    if current() then
      self.cancel_finder = cancel
    else
      pcall(cancel)
    end
  end
end

---Replace the current candidate list, preserving original item values.
function Picker:set_items(items)
  if not self.closed then
    self:_set_items(items)
  end
end

---Update the search input. Live sources restart; static sources filter locally.
function Picker:set_search_options(changes)
  return require("selection_tools.search_options").set(self, changes)
end

function Picker:set_query(query)
  if self.closed then
    return
  end
  if not api.nvim_buf_is_valid(self.input_buf) then
    self:close()
    return
  end
  query = tostring(query):gsub("[\r\n]", " ")
  local lines = api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  if #lines ~= 1 or lines[1] ~= query then
    api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { query })
  end
  if self.query == query then
    return
  end
  self.query = query
  if not self.navigating_history then
    self.history_cursor, self.history_draft = #self.history + 1, query
  end
  if self.opts.live and self.opts.finder then
    self:_find()
  else
    self:_filter()
  end
end

function Picker:move(delta)
  if not self.closed and #self.matches > 0 then
    self.index = ((self.index - 1 + delta) % #self.matches) + 1
    self:_render()
  end
end

---Move in screen coordinates, respecting a reversed result list.
function Picker:move_visual(delta)
  self:move(self.opts.layout.reverse and -delta or delta)
end

function Picker:scroll_list(direction)
  if self.closed or #self.matches == 0 then
    return
  end
  local delta = direction * math.max(1, math.floor(self.height / 2))
  if self.opts.layout.reverse then
    delta = -delta
  end
  self.index = math.max(1, math.min(#self.matches, self.index + delta))
  self:_render()
end

function Picker:scroll_preview(direction)
  if self.closed or not self.preview_win or not api.nvim_win_is_valid(self.preview_win) then
    return
  end
  local amount = math.max(1, math.floor(api.nvim_win_get_height(self.preview_win) / 2))
  api.nvim_win_call(self.preview_win, function()
    vim.cmd("normal! " .. amount .. (direction > 0 and "\004" or "\021"))
  end)
end

function Picker:toggle()
  if self.closed or not self.opts.multi then
    return
  end
  local entry = self.matches[self.index]
  if entry then
    self.marks[entry.index] = not self.marks[entry.index] or nil
    self:_render()
  end
end

---Return marked items in source order, optionally falling back to the cursor.
function Picker:selected(opts)
  local items = {}
  for _, entry in ipairs(self.entries) do
    if self.marks[entry.index] then
      items[#items + 1] = entry.item
    end
  end
  if #items == 0 and opts and opts.fallback then
    local item, index = self:current()
    if index then
      items[1] = item
    end
  end
  return items
end

function Picker:history_move(direction)
  if self.closed or #self.history == 0 then
    return
  end
  if self.history_cursor == #self.history + 1 then
    self.history_draft = self.query
  end
  self.history_cursor = math.max(1, math.min(#self.history + 1, self.history_cursor + direction))
  self.navigating_history = true
  self:set_query(self.history[self.history_cursor] or self.history_draft)
  self.navigating_history = false
end

---@return any item
---@return integer|nil original_index
function Picker:current()
  local entry = not self.closed and self.matches[self.index] or nil
  if entry then
    return entry.item, entry.index
  end
end

---Report the backend used for the current query and any fallback error.
function Picker:matcher_status()
  return { backend = self.match_backend or "none", pending = self.matching == true, error = self.matcher.last_error }
end

function Picker:_restore_preview()
  if self.restore_view and self.preview and self.preview_win and self.preview.displayed_item == self:current() then
    api.nvim_win_call(self.preview_win, function()
      vim.fn.winrestview(self.restore_view)
    end)
    self.restore_view = nil
  end
end

function Picker:_apply_restore()
  local saved = self.restore_pending
  if not saved or self.loading or self.matching then
    return
  end
  local state = require("selection_tools.state")
  self.restore_pending = nil
  self.marks = {}
  for _, entry in ipairs(self.entries) do
    if
      (saved.refreshed and saved.marked_keys[state.key(entry)]) or (not saved.refreshed and saved.marks[entry.index])
    then
      self.marks[entry.index] = true
    end
  end
  for index, entry in ipairs(self.matches) do
    if (saved.refreshed and state.key(entry) == saved.key) or (not saved.refreshed and entry.index == saved.index) then
      self.index, self.offset, self.restore_view = index, saved.offset, saved.view
      break
    end
  end
end

function Picker:restore(saved)
  if self.closed then
    return
  end
  self.restore_pending = saved
  self:_apply_restore()
  self:_render()
end

function Picker:confirm()
  if self.closed then
    return
  end
  local item, index = self:current()
  if index then
    self:close(item, index, self:selected({ fallback = true }))
  end
end

---Close and call on_choice exactly once. No arguments means cancellation.
function Picker:close(item, index, selected)
  if self.closed then
    return
  end
  require("selection_tools.state").remember(self)
  self.closed = true
  self.matching = false
  self.matcher:cancel()
  if self.syntax then
    self.syntax:close()
  end
  self:_cancel_finder()
  if self.preview then
    self.preview:cancel()
  end
  require("selection_tools.history").add(self.history_key, self.query, self.opts.history)
  if self.group then
    api.nvim_del_augroup_by_id(self.group)
  end
  local focused = api.nvim_get_current_win()
  local owns_focus = focused == self.input_win or focused == self.list_win or focused == self.preview_win
  if owns_focus then
    vim.cmd.stopinsert()
  end
  for _, win in ipairs(self.separator_wins or {}) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  for _, field in ipairs({ "input_win", "list_win", "preview_win", "frame_win" }) do
    local win = self[field]
    if win and api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  for _, field in ipairs({ "input_buf", "list_buf", "preview_buf", "frame_buf", "separator_buf" }) do
    local buf = self[field]
    if buf and api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
  if owns_focus and api.nvim_win_is_valid(self.origin_win) then
    api.nvim_set_current_win(self.origin_win)
  end
  if active == self then
    active = nil
  end
  if self.opts.on_close then
    local ok, err = pcall(self.opts.on_close, self)
    if not ok then
      notify(err)
    end
  end
  if self.opts.on_choice then
    self.opts.on_choice(item, index, selected)
  end
end

function Picker:_events()
  self.group = api.nvim_create_augroup("SelectionTools" .. self.input_buf, { clear = true })
  api.nvim_buf_attach(self.input_buf, false, {
    on_lines = function()
      vim.schedule(function()
        if not self.closed and api.nvim_buf_is_valid(self.input_buf) then
          self:set_query(table.concat(api.nvim_buf_get_lines(self.input_buf, 0, -1, false), " "))
        end
      end)
    end,
    on_detach = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    callback = function(ev)
      if
        tonumber(ev.match) == self.input_win
        or tonumber(ev.match) == self.list_win
        or tonumber(ev.match) == self.preview_win
        or tonumber(ev.match) == self.frame_win
      then
        vim.schedule(function()
          self:close()
        end)
      end
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    group = self.group,
    callback = function()
      vim.schedule(function()
        local win = api.nvim_get_current_win()
        if
          not self.closed
          and not self.prompting
          and win ~= self.input_win
          and win ~= self.list_win
          and win ~= self.preview_win
        then
          self:close()
        end
      end)
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = self.group,
    callback = function()
      local ok, resolved = pcall(self._layout, self)
      if not ok then
        self:close()
        return
      end
      if self.preview_win and not resolved.preview then
        local win = self.preview_win
        self.preview_win = nil
        self.preview:cancel()
        api.nvim_win_close(win, true)
      elseif resolved.preview and not self.preview_win then
        self.preview_win = api.nvim_open_win(self.preview_buf, false, resolved.preview)
        self.preview.initialized = false
        vim.wo[self.preview_win].wrap = false
        vim.wo[self.preview_win].list = false
        vim.wo[self.preview_win].foldenable = false
        vim.wo[self.preview_win].scrolloff = 0
        vim.wo[self.preview_win].number = true
        vim.wo[self.preview_win].relativenumber = false
        vim.wo[self.preview_win].winhighlight = "Normal:NormalFloat,FloatBorder:SelectionToolsBorder"
      end
      for _, name in ipairs({ "frame", "input", "list", "preview" }) do
        if resolved[name] then
          api.nvim_win_set_config(self[name .. "_win"], resolved[name])
        end
      end
      self:_render()
    end,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = self.group,
    buffer = self.list_buf,
    callback = function()
      local index = self.row_to_index[api.nvim_win_get_cursor(self.list_win)[1]]
      if not self.rendering and index and index ~= self.index then
        self.index = index
        self:_render()
      end
    end,
  })
  local actions = {
    confirm = function()
      self:confirm()
    end,
    close = function()
      self:close()
    end,
    next = function()
      self:move_visual(1)
    end,
    previous = function()
      self:move_visual(-1)
    end,
  }
  actions.select_previous = function()
    self:toggle()
    self:move(-1)
  end
  actions.select_next = function()
    self:toggle()
    self:move(1)
  end
  actions.history_back = function()
    self:history_move(-1)
  end
  actions.history_forward = function()
    self:history_move(1)
  end
  actions.preview_up = function()
    self:scroll_preview(-1)
  end
  actions.preview_down = function()
    self:scroll_preview(1)
  end
  actions.list_up = function()
    self:scroll_list(-1)
  end
  actions.list_down = function()
    self:scroll_list(1)
  end
  actions.copy = function()
    require("selection_tools.actions").copy(self)
  end
  actions.system_open = function()
    require("selection_tools.actions").open(self)
  end
  for _, mode in ipairs({ "split", "vsplit", "tab" }) do
    actions[mode] = function()
      require("selection_tools.actions").edit(self, mode)
    end
  end
  for _, name in ipairs({ "quickfix", "quickfix_all", "loclist", "loclist_all" }) do
    actions[name] = function()
      require("selection_tools.actions").export(self, name:match("^loclist") ~= nil, name:match("_all$") ~= nil)
    end
  end
  for _, name in ipairs({ "regex", "case", "hidden", "ignored", "scope", "globs" }) do
    actions["search_" .. name] = function()
      require("selection_tools.search_options").action(self, name)
    end
  end
  actions.ignore = function() end
  for name, action in pairs(self.opts.actions or {}) do
    actions[name] = function()
      action(self)
    end
  end
  for action, keys in pairs(self.opts.keys) do
    assert(actions[action], "selection-tools: unknown key action: " .. action)
    for _, key in ipairs(keys) do
      for _, buf in ipairs({ self.input_buf, self.list_buf, self.preview_buf }) do
        vim.keymap.set({ "i", "n" }, key, actions[action], { buffer = buf, nowait = true, silent = true })
      end
    end
  end
  vim.keymap.set("n", "j", actions.next, { buffer = self.list_buf })
  vim.keymap.set("n", "k", actions.previous, { buffer = self.list_buf })
  vim.keymap.set("n", "/", function()
    api.nvim_set_current_win(self.input_win)
    vim.cmd.startinsert({ bang = true })
  end, { buffer = self.list_buf })
end

function Picker:_mount(resolved)
  self.frame_buf = scratch("selection_tools_frame")
  self.input_buf, self.list_buf = scratch("selection_tools_input"), scratch("selection_tools_list")
  api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { self.query })
  self.frame_win = api.nvim_open_win(self.frame_buf, false, resolved.frame)
  self.list_win = api.nvim_open_win(self.list_buf, false, resolved.list)
  if self.opts.preview.enabled then
    self.preview_buf = scratch("selection_tools_preview")
    -- A preview_item provider may temporarily display its own buffer in this pane.
    vim.bo[self.preview_buf].bufhidden = "hide"
    if resolved.preview then
      self.preview_win = api.nvim_open_win(self.preview_buf, false, resolved.preview)
    end
    self.preview = require("selection_tools.preview").new(self, self.preview_buf)
  end
  self.input_win = api.nvim_open_win(self.input_buf, true, resolved.input)
  for _, name in ipairs({ "frame", "list", "input", "preview" }) do
    local win = self[name .. "_win"]
    if win then
      vim.wo[win].wrap = false
      vim.wo[win].cursorline = false
      vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:SelectionToolsBorder"
      vim.wo[win].scrolloff = 0
      vim.wo[win].sidescrolloff = 0
      vim.wo[win].list = false
      vim.wo[win].foldenable = false
      if name == "preview" then
        vim.wo[win].number = true
        vim.wo[win].relativenumber = false
      end
    end
  end
  api.nvim_set_hl(0, "SelectionToolsBorder", { default = true, link = "FloatBorder" })
  api.nvim_set_hl(0, "SelectionToolsSelected", { default = true, link = "Visual" })
  api.nvim_set_hl(0, "SelectionToolsMatch", { default = true, link = "Search" })
  local count_hl = api.nvim_get_hl(0, { name = "SelectionToolsCount", link = false, create = false })
  if vim.tbl_isempty(count_hl) then
    count_hl = api.nvim_get_hl(0, { name = "Comment", link = false })
  end
  count_hl.italic = false
  if count_hl.cterm then
    count_hl.cterm.italic = false
  end
  api.nvim_set_hl(0, "SelectionToolsCount", count_hl)
  api.nvim_set_hl(0, "SelectionToolsFileIcon", { default = true, link = "Comment" })
  api.nvim_set_hl(0, "SelectionToolsDirectoryIcon", { default = true, link = "Directory" })
  local file_color = api.nvim_get_hl(0, { name = "Comment", link = false })
  api.nvim_set_hl(
    0,
    "SelectionToolsFileLocation",
    { default = true, fg = file_color.fg, ctermfg = file_color.ctermfg, italic = false }
  )
  api.nvim_set_hl(0, "SelectionToolsPreviewLine", { default = true, link = "CursorLine" })
  api.nvim_set_hl(0, "SelectionToolsPreviewMatch", { default = true, link = "Search" })
  self:_events()
  active = self
  self.started = true
  self:_filter()
  if self.opts.finder then
    self:_find()
  end
  api.nvim_win_set_cursor(self.input_win, { 1, #self.query })
  vim.cmd.startinsert({ bang = true })
end

function Picker.new(opts)
  assert(
    opts.highlight_item == nil or type(opts.highlight_item) == "function",
    "selection-tools: highlight_item must be a function"
  )
  assert(
    opts.format_icon == nil or type(opts.format_icon) == "function",
    "selection-tools: format_icon must be a function"
  )
  assert(type(opts.items) == "table" or type(opts.finder) == "function", "selection-tools: supply items or finder")
  local self = setmetatable({
    opts = opts,
    closed = false,
    query = tostring(opts.query or ""):gsub("[\r\n]", " "),
    entries = {},
    matches = {},
    positions = {},
    index = 1,
    offset = 0,
    generation = 0,
    marks = {},
  }, Picker)
  self.matcher = require("selection_tools.matcher").new(opts.matcher)
  local resolved = self:_layout()
  -- Validate formatting before opening windows or dismissing an existing picker.
  if opts.items then
    self:_set_items(opts.items)
  end
  if active then
    active:close()
  end
  self.history_key = opts.source or opts.kind or opts.prompt or "select"
  self.history = require("selection_tools.history").get(self.history_key, opts.history)
  self.history_cursor, self.history_draft = #self.history + 1, self.query
  self.origin_win = api.nvim_get_current_win()
  local ok, err = pcall(self._mount, self, resolved)
  if not ok then
    -- Failed construction has no selection lifecycle and must not leak UI.
    self.opts.on_choice = nil
    self:close()
    error(err, 0)
  end
  return self
end

return Picker
