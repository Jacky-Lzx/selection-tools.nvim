local util = require("selection_tools.sources.util")

return function(opts)
  local target = util.file_window()
  local current = vim.api.nvim_get_current_buf()
  local items = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if opts.current ~= false or info.bufnr ~= current then
      local name = info.name ~= "" and vim.fn.fnamemodify(info.name, ":~:.") or "[No Name]"
      items[#items + 1] = { bufnr = info.bufnr, text = name, lastused = info.lastused }
    end
  end
  table.sort(items, function(a, b)
    if a.bufnr == current then
      return true
    end
    if b.bufnr == current then
      return false
    end
    if a.lastused == b.lastused then
      return a.bufnr < b.bufnr
    end
    return a.lastused > b.lastused
  end)
  return {
    prompt = "Buffers",
    multi = true,
    preview = { enabled = true },
    items = items,
    format_item = function(item)
      return item.text
    end,
    on_choice = function(item)
      if item and vim.api.nvim_buf_is_valid(item.bufnr) then
        util.focus_file_window(target)
        vim.api.nvim_set_current_buf(item.bufnr)
      end
    end,
  }
end
