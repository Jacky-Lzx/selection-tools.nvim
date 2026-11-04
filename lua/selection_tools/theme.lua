-- Optional shared colors; ordinary standard-highlight defaults remain standalone.
local M = {}
local initialized, stop = false, nil

local function apply(c)
  local groups = {
    SelectionToolsBorder = { fg = c.ui.border, bg = c.ui.float_bg },
    SelectionToolsSelected = { fg = c.ui.selection_fg, bg = c.ui.selection_bg },
    SelectionToolsMatch = { fg = c.ui.search_fg, bg = c.ui.search_bg },
    SelectionToolsMarked = { fg = c.ui.accent, bold = true },
    SelectionToolsUnmarked = { fg = c.ui.muted },
    SelectionToolsMarkSeparator = { fg = c.ui.subtle },
    SelectionToolsCount = { fg = c.ui.muted, italic = false },
    SelectionToolsFileIcon = { fg = c.ui.muted },
    SelectionToolsDirectoryIcon = { fg = c.palette.blue },
    SelectionToolsFileLocation = { fg = c.ui.muted, italic = false },
    SelectionToolsPreviewLine = { bg = c.ui.cursorline_bg },
    SelectionToolsPreviewMatch = { fg = c.ui.search_fg, bg = c.ui.search_bg },
  }
  for name, value in pairs(groups) do
    vim.api.nvim_set_hl(0, name, value)
  end
end

local function attach()
  local themes = package.loaded.theme_tools
  if not stop and type(themes) == "table" and type(themes.on_change) == "function" then
    stop = themes.on_change("selection-tools", apply)
  end
end

function M.setup()
  if initialized then
    return
  end
  initialized = true
  local group = vim.api.nvim_create_augroup("SelectionToolsTheme", { clear = true })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "ThemeToolsReady", callback = attach })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = attach })
  attach()
end

return M
