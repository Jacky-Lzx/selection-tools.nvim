local util = require("selection_tools.sources.util")
return function()
  return {
    prompt = "Help tags",
    finder = function(ctx)
      return require("selection_tools.sources.help_index").load(ctx)
    end,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    on_choice = function(item)
      if item then
        vim.api.nvim_cmd({ cmd = "help", args = { item.tag }, magic = { bar = false } }, {})
      end
    end,
  }
end
