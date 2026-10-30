local util = require("selection_tools.sources.util")
return function()
  local items = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local item = util.definition(autocmd.callback) or {}
    item.text = ("%s %s %s  %s"):format(
      autocmd.event,
      autocmd.group_name or "",
      autocmd.pattern or "",
      autocmd.desc or autocmd.command or ""
    )
    item.detail, item.ft = vim.inspect(autocmd), "lua"
    items[#items + 1] = item
  end
  table.sort(items, function(a, b)
    return a.text < b.text
  end)
  return {
    prompt = "Autocommands",
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    previewer = util.preview,
    on_choice = function(item)
      if item then
        if item.file then
          util.jump(item)
        else
          util.show(item)
        end
      end
    end,
  }
end
