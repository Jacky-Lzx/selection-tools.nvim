vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.env.THEME_TOOLS_DIR or vim.fn.getcwd() .. "/../theme-tools.nvim"
if vim.fn.isdirectory(root) == 0 then
  print("SKIP optional theme ownership integration")
  return
end
vim.opt.rtp:append(root)
local api = vim.api
vim.cmd.colorscheme("theme-tools-mocha")
api.nvim_set_hl(0, "SelectionToolsMarked", { fg = "#123456" })
api.nvim_set_hl(0, "SelectionToolsCount", { fg = "#654321", italic = true })
local picker = require("selection_tools").open({ items = { "alpha", "beta" }, multi = true })
assert(not package.loaded.theme_tools)
local t = require("theme_tools")
t.setup({
  persist = false,
  catppuccin = false,
  dracula = false,
  themes = { "theme-tools-mocha", "morning" },
  icons = { default = "none" },
})
local function hl(name)
  return api.nvim_get_hl(0, { name = name, link = false })
end
local function explicit()
  assert(hl("SelectionToolsMarked").fg == 0x123456)
  assert(hl("SelectionToolsCount").fg == 0x654321 and hl("SelectionToolsCount").italic)
end
explicit()
t.refresh_palette()
explicit()
picker:close()
require("selection_tools").setup()
picker = require("selection_tools").open({ items = { "alpha", "beta" } })
explicit()
local snapshot = require("theme_tools.colors").snapshot()
assert(t.set("morning"))
assert(hl("SelectionToolsMarked").fg ~= 0x123456, "old explicit color leaked to a new scheme")
require("theme_tools.colors").restore(snapshot)
explicit()
local group = api.nvim_create_augroup("SelectionOwnershipTest", { clear = true })
api.nvim_create_autocmd("ColorScheme", {
  group = group,
  pattern = "morning",
  callback = function()
    api.nvim_set_hl(0, "SelectionToolsMatch", { fg = "#abcdef", bold = true })
  end,
})
vim.cmd.colorscheme("morning")
vim.wait(20)
assert(hl("SelectionToolsMatch").fg == 0xabcdef and hl("SelectionToolsMatch").bold)
t.refresh_palette()
assert(hl("SelectionToolsMatch").fg == 0xabcdef)
api.nvim_set_hl(0, "SelectionToolsMarked", { link = "DiagnosticWarn" })
t.refresh_palette()
assert(api.nvim_get_hl(0, { name = "SelectionToolsMarked" }).link == "DiagnosticWarn")
api.nvim_set_hl(0, "SelectionToolsBorder", {})
t.refresh_palette()
assert(hl("SelectionToolsBorder").fg)
picker:close()
print(
  "selection ownership: standalone and late theme defaults, explicit styles/links, setup, switches and rollback passed"
)
