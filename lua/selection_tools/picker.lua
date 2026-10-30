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
  return tostring(value):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "  ")
end

local function dimension(value, available)
  return math.max(1, math.min(available, math.floor(value <= 1 and available * value or value)))
end

function Picker:_layout()
  local columns, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  assert(columns >= 12 and lines >= 8, "selection-tools: window requires at least 12 columns and 8 rows")
  local layout = self.opts.layout
  local width = dimension(layout.width, columns - 4)
  local height = dimension(layout.height, lines - 6)
  local row = math.max(0, math.floor((lines - height - 5) / 2))
  local col = math.floor((columns - width - 2) / 2)
  local common =
    { relative = "editor", style = "minimal", border = layout.border, width = width, col = col, zindex = 60 }
  local input = vim.tbl_extend("force", common, {
    row = row,
    height = 1,
    title = " " .. single_line(self.opts.prompt or "Select") .. " ",
    title_pos = "left",
  })
  local list = vim.tbl_extend("force", common, { row = row + 3, height = height })
  self.height = height
  return input, list
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

function Picker:_set_items(items)
  assert(type(items) == "table", "finder results must be a list")
  local entries, candidates = {}, {}
  for index, item in ipairs(items) do
    local text = self.opts.format_item and self.opts.format_item(item) or tostring(item)
    entries[index] = { item = item, index = index, text = single_line(text) }
    candidates[index] = { index = index, text = entries[index].text }
  end
  self.entries, self.candidates = entries, candidates
  self:_filter()
end

function Picker:_filter()
  if self.closed then
    return
  end
  self.positions = {}
  if self.query == "" or self.opts.match == false then
    self.matches = self.entries
  else
    local result = vim.fn.matchfuzzypos(self.candidates, self.query, { key = "text", matchseq = 1 })
    -- Vimscript conversion copies dictionaries; resolve back to original Lua items.
    self.matches = {}
    for _, entry in ipairs(result[1]) do
      self.matches[#self.matches + 1] = self.entries[entry.index]
    end
    self.positions = result[2]
  end
  self.index, self.offset = 1, 0
  self:_render()
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
  for i = self.offset + 1, math.min(count, self.offset + self.height) do
    lines[#lines + 1] = self.matches[i].text
  end
  if count == 0 then
    lines[1] = self.error and ("Error: " .. single_line(self.error)) or (self.loading and "Loading…" or "No results")
  end
  vim.bo[self.list_buf].modifiable = true
  api.nvim_buf_set_lines(self.list_buf, 0, -1, false, lines)
  vim.bo[self.list_buf].modifiable = false
  api.nvim_buf_clear_namespace(self.list_buf, ns, 0, -1)
  if count > 0 then
    for row = 1, #lines do
      for _, pos in ipairs(self.positions[self.offset + row] or {}) do
        local start = vim.fn.byteidx(lines[row], pos)
        local finish = vim.fn.byteidx(lines[row], pos + 1)
        api.nvim_buf_set_extmark(self.list_buf, ns, row - 1, start, {
          end_col = finish,
          hl_group = "SelectionToolsMatch",
          priority = 110,
        })
      end
    end
    api.nvim_buf_set_extmark(self.list_buf, ns, self.index - self.offset - 1, 0, {
      line_hl_group = "SelectionToolsSelected",
      priority = 100,
    })
    api.nvim_win_set_cursor(self.list_win, { self.index - self.offset, 0 })
  else
    api.nvim_buf_set_extmark(self.list_buf, ns, 0, 0, { line_hl_group = "Comment" })
  end
  local status = self.error and "Error" or (self.loading and "Loading" or tostring(#self.entries))
  api.nvim_win_set_config(self.list_win, { footer = (" %d / %s "):format(count, status), footer_pos = "right" })
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

---@return any item
---@return integer|nil original_index
function Picker:current()
  local entry = not self.closed and self.matches[self.index] or nil
  if entry then
    return entry.item, entry.index
  end
end

function Picker:confirm()
  if self.closed then
    return
  end
  local item, index = self:current()
  if index then
    self:close(item, index)
  end
end

---Close and call on_choice exactly once. No arguments means cancellation.
function Picker:close(item, index)
  if self.closed then
    return
  end
  self.closed = true
  self:_cancel_finder()
  if self.group then
    api.nvim_del_augroup_by_id(self.group)
  end
  local focused = api.nvim_get_current_win()
  local owns_focus = focused == self.input_win or focused == self.list_win
  if owns_focus then
    vim.cmd.stopinsert()
  end
  for _, field in ipairs({ "input_win", "list_win" }) do
    local win = self[field]
    if win and api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  for _, field in ipairs({ "input_buf", "list_buf" }) do
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
  if self.opts.on_choice then
    self.opts.on_choice(item, index)
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
      if tonumber(ev.match) == self.input_win or tonumber(ev.match) == self.list_win then
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
        if not self.closed and win ~= self.input_win and win ~= self.list_win then
          self:close()
        end
      end)
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = self.group,
    callback = function()
      local ok, input, list = pcall(self._layout, self)
      if not ok then
        self:close()
        return
      end
      api.nvim_win_set_config(self.input_win, input)
      api.nvim_win_set_config(self.list_win, list)
      self:_render()
    end,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = self.group,
    buffer = self.list_buf,
    callback = function()
      local index = self.offset + api.nvim_win_get_cursor(self.list_win)[1]
      if #self.matches > 0 and index ~= self.index then
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
      self:move(1)
    end,
    previous = function()
      self:move(-1)
    end,
  }
  for action, keys in pairs(self.opts.keys) do
    assert(actions[action], "selection-tools: unknown key action: " .. action)
    for _, key in ipairs(keys) do
      for _, buf in ipairs({ self.input_buf, self.list_buf }) do
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

function Picker:_mount(input, list)
  self.input_buf, self.list_buf = scratch("selection_tools_input"), scratch("selection_tools_list")
  api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { self.query })
  self.list_win = api.nvim_open_win(self.list_buf, false, list)
  self.input_win = api.nvim_open_win(self.input_buf, true, input)
  for _, win in ipairs({ self.input_win, self.list_win }) do
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:SelectionToolsBorder"
    vim.wo[win].scrolloff = 0
  end
  api.nvim_set_hl(0, "SelectionToolsBorder", { default = true, link = "FloatBorder" })
  api.nvim_set_hl(0, "SelectionToolsSelected", { default = true, link = "Visual" })
  api.nvim_set_hl(0, "SelectionToolsMatch", { default = true, link = "Search" })
  self:_events()
  active = self
  self:_filter()
  if self.opts.finder then
    self:_find()
  end
  api.nvim_win_set_cursor(self.input_win, { 1, #self.query })
  vim.cmd.startinsert({ bang = true })
end

function Picker.new(opts)
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
  }, Picker)
  local input, list = self:_layout()
  -- Validate formatting before opening windows or dismissing an existing picker.
  if opts.items then
    self:_set_items(opts.items)
  end
  if active then
    active:close()
  end
  self.origin_win = api.nvim_get_current_win()
  local ok, err = pcall(self._mount, self, input, list)
  if not ok then
    -- Failed construction has no selection lifecycle and must not leak UI.
    self.opts.on_choice = nil
    self:close()
    error(err, 0)
  end
  return self
end

return Picker
