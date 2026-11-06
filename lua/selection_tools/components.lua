-- Descriptors contain no per-item state and can be shared between sources.
local M = {}

---@class selection_tools.Component
---@field kind string
---@field field? string
---@field get? fun(item: any, index: integer): any
---@field hl? string|false
---@field searchable? boolean
---@field highlights? fun(item: any, index: integer): table[]
---@field width? integer
---@field min_width? integer
---@field max_width? integer
---@field grow? number
---@field priority? number
---@field align? 'left'|'right'
---@field truncate? 'left'|'right'|'match'

for _, kind in ipairs({ "text", "path", "position", "time", "icon" }) do
  M[kind] = function(opts)
    assert(opts == nil or type(opts) == "table", "selection-tools: component options must be a table")
    return vim.tbl_extend("force", {}, opts or {}, { kind = kind })
  end
end

return M
