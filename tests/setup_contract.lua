vim.opt.rtp:prepend(vim.fn.getcwd())
local original_select = vim.ui.select
local plugin = require("selection_tools")
local options = { ui_select = true, layout = { width = 0.7 } }
local caller = vim.deepcopy(options)
plugin.setup(options)
assert(vim.deep_equal(caller, options), "setup mutated caller configuration")
local commands = vim.api.nvim_get_commands({})
local handlers = vim.api.nvim_get_autocmds({})
assert(not pcall(plugin.setup, false), "setup(false) must reject an invalid configuration type")
assert(vim.deep_equal(commands, vim.api.nvim_get_commands({})), "Invalid setup replaced commands")
assert(vim.deep_equal(handlers, vim.api.nvim_get_autocmds({})), "Invalid setup replaced handlers")
plugin.setup(caller)
assert(#vim.api.nvim_get_autocmds({}) == #handlers, "Repeated setup duplicated automatic handlers")
print("selection-tools.nvim: setup input isolation, invalid configuration and registration lifetime passed")

local adapter = vim.ui.select
assert(not pcall(plugin.setup, { layout = { width = -1 } }))
assert(vim.ui.select == adapter)
local picker = plugin.open({ items = { "one", "two" } })
local user = function() end
vim.ui.select = user
plugin.dispose()
plugin.dispose()
assert(picker.closed and vim.ui.select == user)
assert(vim.fn.exists("#SelectionToolsTheme") == 0)
plugin.setup(caller)
assert(vim.ui.select ~= user)
plugin.dispose()
assert(vim.ui.select == user)

vim.ui.select = original_select
