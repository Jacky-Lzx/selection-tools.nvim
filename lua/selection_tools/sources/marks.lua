local util = require("selection_tools.sources.util")

return function(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local marks = vim.fn.getmarklist(buf)
  vim.list_extend(marks, vim.fn.getmarklist())
  local items, seen = {}, {}
  for _, mark in ipairs(marks) do
    if mark.pos[2] > 0 and not seen[mark.mark] then
      local bufnr = mark.pos[1] > 0 and mark.pos[1] or buf
      local file = mark.file or vim.api.nvim_buf_get_name(bufnr)
      if file ~= "" then
        file = vim.fn.fnamemodify(file, ":p")
      else
        file = nil
      end
      items[#items + 1] = {
        name = mark.mark,
        bufnr = vim.api.nvim_buf_is_valid(bufnr) and bufnr or nil,
        file = file,
        pos = { mark.pos[2], math.max(0, mark.pos[3] - 1) },
        text = ("%s  %s:%d:%d"):format(
          mark.mark,
          file and vim.fn.fnamemodify(file, ":~:.") or "[No Name]",
          mark.pos[2],
          mark.pos[3]
        ),
      }
      seen[mark.mark] = true
    end
  end
  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  return {
    prompt = "Marks",
    items = items,
    resume_refresh = true,
    preview = { enabled = true },
    components = not opts.format_item and {
      { kind = "icon" },
      { kind = "text", field = "name" },
      { kind = "path" },
      {
        kind = "text",
        get = function(item)
          return not item.file and "[No Name]" or nil
        end,
      },
      { kind = "position" },
    } or nil,
    format_item = util.format,
    on_choice = util.jump,
  }
end
