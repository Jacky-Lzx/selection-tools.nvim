local M = {}

local defaults = {
  ui_select = false,
  item_icons = { enabled = true },
  syntax = { enabled = false, max_size = 1024 * 1024, max_lines = 10000, cache_size = 8 },
  layout = {
    width = 0.6,
    height = 0.5,
    border = "rounded",
    title_pos = "center",
    input_position = "top",
    reverse = false,
    preview_height = 0.6,
  },
  preview = {
    enabled = false,
    providers = {},
    max_size = 1024 * 1024,
    max_lines = 10000,
    max_line_length = 1000,
    highlight_line = true,
    highlight_matches = true,
    scrollbar = true,
    position = true,
  },
  history = { limit = 100, persist = false },
  matcher = {
    backend = "auto",
    threshold = 50000,
    skim = { command = "sk", algorithm = "arinae", debounce_ms = 10, timeout_ms = 10000 },
  },
  select = {
    layout = { width = 0.5, min_width = 80, max_width = 100, height = 0.4, input_position = "top", reverse = false },
    preview = { enabled = false },
    multi = false,
  },
  keys = {
    confirm = { "<CR>" },
    close = { "<Esc>", "<C-c>" },
    next = { "<C-n>", "<Down>" },
    previous = { "<C-p>", "<Up>" },
    quickfix = { "<C-q>" },
    loclist = { "<C-l>" },
    split = { "<C-x>" },
    vsplit = { "<C-v>" },
    tab = { "<C-t>" },
    details = { "<F2>" },
    preview_expand = { "<F3>" },
    search_regex = { "<A-r>" },
    search_case = { "<A-c>" },
    search_hidden = { "<A-h>" },
    search_ignored = { "<A-i>" },
    search_scope = { "<A-f>" },
    search_globs = { "<A-g>" },
  },
}

local config = vim.deepcopy(defaults)
local sources = {}
local builtins = require("selection_tools.sources")
local previous_select
local select_adapter = function(...)
  return M.select(...)
end

---@param opts? table
function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "selection-tools.nvim: setup expects a table")
  opts = vim.deepcopy(opts or {})
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  assert(type(candidate.ui_select) == "boolean", "ui_select must be boolean")
  assert(type(candidate.layout) == "table", "layout must be a table")
  for _, key in ipairs({ "width", "height", "preview_height" }) do
    local value = candidate.layout[key]
    assert(type(value) == "number" and value > 0 and value < math.huge, "layout." .. key .. " must be positive")
  end
  assert(type(candidate.layout.reverse) == "boolean", "layout.reverse must be boolean")
  assert(
    candidate.layout.input_position == "top" or candidate.layout.input_position == "bottom",
    "invalid input_position"
  )
  require("selection_tools.border_labels").validate(candidate.layout)
  assert(
    type(candidate.preview) == "table" and type(candidate.preview.enabled) == "boolean",
    "preview.enabled must be boolean"
  )
  require("selection_tools.theme").setup()
  config = candidate
  if config.ui_select and vim.ui.select ~= select_adapter then
    previous_select = vim.ui.select
    vim.ui.select = select_adapter
  elseif not config.ui_select and vim.ui.select == select_adapter then
    vim.ui.select = previous_select
    previous_select = nil
  end
end

function M.dispose()
  local picker = package.loaded["selection_tools.picker"]
  if picker then
    picker.dispose()
  end
  if vim.ui.select == select_adapter then
    vim.ui.select = previous_select
  end
  previous_select = nil
  local theme = package.loaded["selection_tools.theme"]
  if theme then
    theme.dispose()
  end
  config = vim.deepcopy(defaults)
end

---Open a searchable picker. See :help selection-tools-api.
---@param opts table
---@return selection_tools.Picker
function M.open(opts)
  return require("selection_tools.picker").new(vim.tbl_deep_extend("force", {}, config, opts or {}))
end

---Return the live picker owning a window, including a suspended parent.
function M.current(win)
  local picker = package.loaded["selection_tools.picker"]
  return picker and picker.for_window(win) or nil
end

---vim.ui.select-compatible callback; index always refers to the original list.
---@param items table
---@param opts? table
---@param on_choice fun(item: any, index: integer|nil)
---@return selection_tools.Picker
function M.select(items, opts, on_choice)
  assert(type(items) == "table", "selection-tools: items must be a list")
  assert(type(on_choice) == "function", "selection-tools: on_choice must be a function")
  opts = vim.tbl_deep_extend("force", {}, config.select, opts or {})
  opts.items, opts.on_choice = items, on_choice
  if opts.preview_item then
    opts.preview.enabled = true
  end
  return M.open(opts)
end

---A source is a picker options table or a factory receiving per-call options.
---@param name string
---@param source table|function
function M.register_source(name, source)
  assert(type(name) == "string" and name:match("^[%w_%-]+$"), "selection-tools: invalid source name")
  assert(type(source) == "table" or type(source) == "function", "selection-tools: invalid source")
  sources[name] = source
end

---@return string[]
function M.sources()
  local names = { resume = true }
  for _, name in ipairs(builtins.names) do
    names[name] = true
  end
  for name in pairs(sources) do
    names[name] = true
  end
  return vim.fn.sort(vim.tbl_keys(names))
end

---@param name string
---@param opts? table
---@return selection_tools.Picker
function M.pick(name, opts)
  if name == "resume" then
    return M.resume(opts)
  end
  local source = sources[name]
  if not source then
    source = builtins[name]
  end
  assert(source, "selection-tools: unknown source: " .. tostring(name))
  opts = opts or {}
  local spec = type(source) == "function" and source(opts) or source
  return M.open(vim.tbl_deep_extend("force", {}, spec, opts, { source = name, source_opts = opts }))
end

function M.resume(opts)
  local saved = require("selection_tools.state").get()
  if not saved then
    vim.notify("selection-tools: no picker to resume", vim.log.levels.INFO)
    return
  end
  local picker
  if saved.opts.live or saved.opts.resume_refresh or saved.loading then
    saved.refreshed = true
    local call_opts = vim.tbl_extend("force", {}, saved.opts.source_opts or {}, opts or {}, { query = saved.query })
    picker = saved.opts.source and M.pick(saved.opts.source, call_opts)
      or M.open(vim.tbl_extend("force", {}, saved.opts, call_opts))
  else
    local spec = vim.tbl_extend("force", {}, saved.opts, opts or {}, { items = saved.items, query = saved.query })
    spec.finder = nil
    picker = M.open(spec)
  end
  picker:restore(saved)
  return picker
end

for _, name in ipairs(builtins.names) do
  M[name] = function(opts)
    return M.pick(name, opts)
  end
end

return M
