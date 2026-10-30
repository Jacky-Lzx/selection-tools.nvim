local util = require("selection_tools.sources.util")
return function(loclist)
  local origin = util.capture()
  local function get()
    local what = { items = 1, title = 1, id = 0 }
    return loclist and vim.fn.getloclist(origin.win, what) or vim.fn.getqflist(what)
  end
  local list, items = get(), {}
  for i, entry in ipairs(list.items or {}) do
    local file = entry.bufnr > 0 and vim.api.nvim_buf_is_valid(entry.bufnr) and vim.api.nvim_buf_get_name(entry.bufnr)
      or ""
    items[#items + 1] = {
      index = i,
      entry = entry,
      bufnr = entry.bufnr > 0 and entry.bufnr or nil,
      file = file ~= "" and file or nil,
      pos = { math.max(1, entry.lnum), math.max(0, entry.col - 1) },
      text = ("%d %s:%d:%d: %s"):format(i, file, entry.lnum, entry.col, entry.text),
    }
  end
  return {
    prompt = (loclist and "Location list" or "Quickfix") .. ": " .. (list.title or ""),
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    on_choice = function(item)
      if not item or item.entry.valid == 0 then
        return
      end
      util.context(origin, function()
        local current = get()
        if current.id ~= list.id or not vim.deep_equal(current.items[item.index], item.entry) then
          vim.notify("selection-tools: list changed; reopen the picker", vim.log.levels.WARN)
          return
        end
        vim.cmd((loclist and "ll " or "cc ") .. item.index)
      end)
    end,
  }
end
