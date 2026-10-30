local M = {}
local last

function M.key(entry)
  local item = entry.item
  if type(item) == "table" and (item.file or item.bufnr) then
    local pos = item.pos or {}
    return tostring(item.file or item.bufnr) .. "\0" .. tostring(pos[1] or 0) .. ":" .. tostring(pos[2] or 0)
  end
  return entry.text .. "\0" .. entry.index
end

function M.remember(picker)
  if not picker.started or picker.opts.resume == false then
    return
  end
  local items, marked_keys = {}, {}
  for i, entry in ipairs(picker.entries) do
    items[i] = entry.item
    if picker.marks[entry.index] then
      marked_keys[M.key(entry)] = true
    end
  end
  local entry = picker.matches[picker.index]
  local view
  if picker.preview_win and vim.api.nvim_win_is_valid(picker.preview_win) then
    view = vim.api.nvim_win_call(picker.preview_win, vim.fn.winsaveview)
  end
  last = {
    opts = vim.tbl_extend("force", {}, picker.opts),
    items = items,
    query = picker.query,
    index = entry and entry.index,
    key = entry and M.key(entry),
    marks = vim.deepcopy(picker.marks),
    marked_keys = marked_keys,
    offset = picker.offset,
    view = view,
    loading = picker.loading,
  }
end

function M.get()
  return last and vim.tbl_extend("force", {}, last) or nil
end
return M
