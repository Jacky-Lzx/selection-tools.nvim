if vim.g.loaded_selection_tools then
  return
end
vim.g.loaded_selection_tools = true

vim.api.nvim_create_user_command("SelectionTools", function(args)
  local tools = require("selection_tools")
  local name = args.fargs[1] or "files"
  local ok, err = pcall(tools.pick, name)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  desc = "Open a selection-tools search source (default: files)",
  complete = function(prefix)
    return vim.tbl_filter(function(name)
      return name:sub(1, #prefix) == prefix
    end, require("selection_tools").sources())
  end,
})
