local M = {}

-- Prefer explicit marks; otherwise export the complete filtered result set.
function M.export(picker, location, all)
  if picker.closed or picker.matching then
    return
  end
  local items = not all and picker:selected() or {}
  if #items == 0 then
    for _, entry in ipairs(picker.matches) do
      items[#items + 1] = entry.item
    end
  end
  local entries = {}
  for _, item in ipairs(items) do
    if type(item) == "table" and (item.file or item.bufnr or item.buf) then
      local pos = item.pos or { 1, 0 }
      entries[#entries + 1] = {
        filename = item.file,
        bufnr = item.bufnr or item.buf,
        lnum = pos[1],
        col = (pos[2] or 0) + 1,
        text = tostring(item.code or item.text or ""):gsub("[\r\n]", " "),
      }
    end
  end
  if #entries == 0 then
    vim.notify("No file locations to export", vim.log.levels.INFO)
    return
  end
  if location and not vim.api.nvim_win_is_valid(picker.origin_win) then
    vim.notify("The original window is no longer available", vim.log.levels.WARN)
    return
  end
  local list = { title = (picker.opts.prompt or "Selection") .. ": " .. picker.query, items = entries }
  if location then
    vim.fn.setloclist(picker.origin_win, {}, " ", list)
  else
    vim.fn.setqflist({}, " ", list)
  end
  picker:close()
  if location then
    vim.api.nvim_set_current_win(picker.origin_win)
  end
  vim.cmd(location and "lopen" or "copen")
end

function M.edit(picker, mode)
  if picker.closed or picker.matching then
    return
  end
  local commands = { split = "split", vsplit = "vsplit", tab = "tabnew" }
  assert(commands[mode], "Unknown open mode")
  local items = vim.tbl_filter(function(item)
    return type(item) == "table" and not item.dir and (item.file or item.bufnr or item.buf)
  end, picker:selected({ fallback = true }))
  if #items == 0 then
    vim.notify("No file locations to open", vim.log.levels.INFO)
    return
  end
  local origin = picker.origin_win
  picker:close()
  if vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  for _, item in ipairs(items) do
    vim.cmd(commands[mode])
    require("selection_tools.sources.util").jump(vim.tbl_extend("force", {}, item, { bufnr = item.bufnr or item.buf }))
  end
end

local function value(item)
  if type(item) ~= "table" then
    return tostring(item)
  end
  if item.file then
    return item.file
  end
  if item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
    local name = vim.api.nvim_buf_get_name(item.bufnr)
    if name ~= "" then
      return name
    end
  end
  return item.text
end

function M.copy(picker)
  local values = {}
  for _, item in ipairs(picker:selected({ fallback = true })) do
    local text = value(item)
    if text then
      values[#values + 1] = text
    end
  end
  if #values > 0 then
    vim.fn.setreg("+", table.concat(values, "\n"))
    vim.notify(("Copied %d item(s) to clipboard"):format(#values), vim.log.levels.INFO, { title = "Selection" })
  end
end

function M.open(picker)
  for _, item in ipairs(picker:selected({ fallback = true })) do
    local target = value(item)
    if target then
      local _, err
      if picker.opts.system_open then
        _, err = picker.opts.system_open(target)
      else
        _, err = vim.ui.open(target)
      end
      if err then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Selection" })
      end
    end
  end
end

return M
