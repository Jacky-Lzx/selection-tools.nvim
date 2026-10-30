local util = require("selection_tools.sources.util")
return function()
  local origin, items = util.capture(), {}
  for i = vim.fn.histnr(":"), 1, -1 do
    local command = vim.fn.histget(":", i)
    if command ~= "" then
      items[#items + 1] = { command = command, text = command, ft = "vim" }
    end
  end
  return {
    prompt = "Command history",
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    previewer = util.preview,
    on_choice = function(item)
      if item then
        util.context(origin, function()
          vim.fn.histadd(":", item.command)
          vim.cmd(item.command)
        end)
      end
    end,
  }
end
