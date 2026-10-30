local M = {}

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
