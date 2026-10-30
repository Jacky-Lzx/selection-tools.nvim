local util = require("selection_tools.sources.util")
return function()
  local origin, items = util.capture(), {}
  for i = vim.fn.histnr("/"), 1, -1 do
    local pattern = vim.fn.histget("/", i)
    if pattern ~= "" then
      items[#items + 1] = { key = pattern, pattern = pattern, text = pattern }
    end
  end
  return {
    prompt = "Search history",
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    previewer = util.preview,
    on_choice = function(item)
      if item then
        util.context(origin, function()
          vim.fn.setreg("/", item.pattern)
          vim.fn.histadd("/", item.pattern)
          vim.v.hlsearch = 1
          vim.fn.search(item.pattern)
        end)
      end
    end,
  }
end
