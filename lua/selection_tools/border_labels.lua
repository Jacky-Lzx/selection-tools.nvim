local M = {}
local slots = { top = true, middle = true, bottom = true }
local alignments = { left = true, center = true, right = true }

function M.validate(layout)
  if layout.labels == nil then
    return
  end
  assert(type(layout.labels) == "table", "selection-tools: layout.labels must be a table")
  for name, label in pairs(layout.labels) do
    assert(slots[name], "selection-tools: unknown border label: " .. tostring(name))
    assert(type(label) == "table", "selection-tools: layout.labels." .. name .. " must be a table")
    assert(label.align == nil or alignments[label.align], "selection-tools: invalid border label alignment: " .. name)
    local kind = type(label.text)
    assert(
      label.text == nil or label.text == false or kind == "string" or kind == "function",
      "selection-tools: invalid border label text: " .. name
    )
  end
end

function M.resolve(picker, name, default, alignment)
  local layout = picker.opts.layout
  local label = (layout.labels or {})[name] or {}
  local value = label.text
  if type(value) == "function" then
    local ok, result = pcall(value, picker, default)
    if ok and (result == nil or result == false or type(result) == "string") then
      value = result
    else
      picker.label_errors = picker.label_errors or {}
      if not picker.label_errors[name] then
        picker.label_errors[name] = true
        vim.notify(
          "selection-tools: layout.labels."
            .. name
            .. ".text: "
            .. (ok and "expected string, false or nil" or tostring(result)),
          vim.log.levels.WARN
        )
      end
      value = nil
    end
  end
  if value == nil then
    value = default
  end
  if value == false or value == "" then
    value = nil
  end
  return value, label.align or alignment or layout.title_pos
end

return M
