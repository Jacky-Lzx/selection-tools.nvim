local util = require("selection_tools.sources.util")
return function()
  local items, seen = {}, {}
  for _, path in ipairs(vim.api.nvim_get_runtime_file("doc/tags", true)) do
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok then
      for _, line in ipairs(lines) do
        local tag, file = line:match("^([^\t]+)\t([^\t]+)\t")
        if tag and tag:sub(1, 1) ~= "!" and not seen[tag] then
          seen[tag] = true
          items[#items + 1] = {
            tag = tag,
            text = tag .. "  " .. file,
            file = vim.fs.joinpath(vim.fs.dirname(path), file),
            search = "*" .. tag .. "*",
            ft = "help",
          }
        end
      end
    end
  end
  table.sort(items, function(a, b)
    return a.tag < b.tag
  end)
  return {
    prompt = "Help tags",
    items = items,
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
