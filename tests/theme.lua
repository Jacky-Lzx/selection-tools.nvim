vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.env.THEME_TOOLS_DIR or vim.fn.fnamemodify(vim.fn.getcwd(), ":h") .. "/theme-tools.nvim"
if vim.fn.isdirectory(root) == 0 then
  print("SKIP optional theme-tools integration (set THEME_TOOLS_DIR)")
  return
end
vim.opt.rtp:append(root)
local tools = require("selection_tools")
tools.setup()
assert(not package.loaded.theme_tools, "selection setup eagerly loaded its optional provider")
local themes = require("theme_tools")
themes.setup({
  persist = false,
  catppuccin = false,
  dracula = false,
  default = "theme-tools-mocha",
  themes = { "theme-tools-mocha", "morning" },
  palette = { overrides = { ui = { accent = "#123456" } } },
})
local api = vim.api
local function check()
  local c = themes.palette()
  local function rgb(color)
    return color == "NONE" and nil or tonumber(color:sub(2), 16)
  end
  assert(api.nvim_get_hl(0, { name = "SelectionToolsBorder", link = false }).fg == rgb(c.ui.border))
  assert(api.nvim_get_hl(0, { name = "SelectionToolsSelected", link = false }).bg == rgb(c.ui.selection_bg))
  assert(api.nvim_get_hl(0, { name = "SelectionToolsMarked", link = false }).fg == 0x123456)
  assert(not api.nvim_get_hl(0, { name = "SelectionToolsCount", link = false }).italic)
end
check()
local p = tools.select({ "alpha", "beta" }, {}, function() end)
check()
local snapshot = require("theme_tools.colors").snapshot()
assert(themes.set("morning"))
check()
require("theme_tools.colors").restore(snapshot)
check()
p:close()
tools.setup()
vim.cmd.colorscheme("morning")
vim.wait(20)
check()
p = tools.select({ "alpha", "beta" }, {}, function() end)
check()
p:close()
print("theme-tools: optional loading, late provider, live picker, overrides, switching and restoration passed")
