local M = {
  names = {
    "files",
    "buffers",
    "grep",
    "projects",
    "recent",
    "todo_comments",
    "registers",
    "jumps",
    "marks",
    "undo",
    "search_history",
    "command_history",
    "qflist",
    "loclist",
    "commands",
    "autocmds",
    "keymaps",
    "help",
    "man",
  },
}

return setmetatable(M, {
  __index = function(self, name)
    if vim.tbl_contains(self.names, name) then
      local source = require("selection_tools.sources." .. name)
      rawset(self, name, source)
      return source
    end
  end,
})
