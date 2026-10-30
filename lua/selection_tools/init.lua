local M = {}

local defaults = {
  ui_select = false,
  layout = { width = 0.6, height = 0.5, border = "rounded" },
  keys = {
    confirm = { "<CR>" },
    close = { "<Esc>", "<C-c>" },
    next = { "<C-n>", "<Down>" },
    previous = { "<C-p>", "<Up>" },
  },
}

local config = vim.deepcopy(defaults)
local sources = {}
local previous_select
local select_adapter = function(...)
  return M.select(...)
end

---@param opts? table
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  if config.ui_select and vim.ui.select ~= select_adapter then
    previous_select = vim.ui.select
    vim.ui.select = select_adapter
  elseif not config.ui_select and vim.ui.select == select_adapter then
    vim.ui.select = previous_select
    previous_select = nil
  end
end

---Open a searchable picker. See :help selection-tools-api.
---@param opts table
---@return selection_tools.Picker
function M.open(opts)
  return require("selection_tools.picker").new(vim.tbl_deep_extend("force", {}, config, opts or {}))
end

---vim.ui.select-compatible callback; index always refers to the original list.
---@param items table
---@param opts? table
---@param on_choice fun(item: any, index: integer|nil)
---@return selection_tools.Picker
function M.select(items, opts, on_choice)
  assert(type(items) == "table", "selection-tools: items must be a list")
  assert(type(on_choice) == "function", "selection-tools: on_choice must be a function")
  opts = vim.tbl_extend("force", {}, opts or {}, { items = items, on_choice = on_choice })
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
  local names = { files = true, buffers = true }
  for name in pairs(sources) do
    names[name] = true
  end
  return vim.fn.sort(vim.tbl_keys(names))
end

---@param name string
---@param opts? table
---@return selection_tools.Picker
function M.pick(name, opts)
  local source = sources[name]
  if not source and (name == "files" or name == "buffers") then
    source = require("selection_tools.sources")[name]
  end
  assert(source, "selection-tools: unknown source: " .. tostring(name))
  opts = opts or {}
  local spec = type(source) == "function" and source(opts) or source
  return M.open(vim.tbl_deep_extend("force", {}, spec, opts))
end

function M.files(opts)
  return M.pick("files", opts)
end

function M.buffers(opts)
  return M.pick("buffers", opts)
end

return M
