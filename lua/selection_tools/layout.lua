local M = {}

local function size(value, available)
  return math.floor(value <= 1 and available * value or value)
end

function M.resolve(opts)
  local columns, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  assert(columns >= 12 and lines >= 8, "selection-tools: window requires at least 12 columns and 8 rows")
  local layout = opts.layout
  require("selection_tools.border_labels").validate(layout)
  local width = math.max(size(layout.width, columns), layout.min_width or 1)
  width = math.max(4, math.min(columns - 4, width, layout.max_width or columns))
  local height = math.max(4, math.min(lines - 2, size(layout.height, lines)))
  local preview_height = 0
  if opts.preview.enabled and height >= 7 then
    preview_height = math.max(1, math.min(height - 5, size(layout.preview_height, height)))
  end
  local list_height = height - 2 - (preview_height > 0 and preview_height + 1 or 0)
  local row, col = math.floor((lines - height - 2) / 2), math.floor((columns - width - 2) / 2)
  local common = { relative = "editor", style = "minimal", border = "none", width = width, col = col + 1, zindex = 61 }
  local result = {
    frame = {
      relative = "editor",
      style = "minimal",
      row = row,
      col = col,
      width = width,
      height = height,
      border = layout.border,
      zindex = 60,
      focusable = false,
      title = " " .. tostring(opts.prompt or "Select"):gsub("[\r\n]", " ") .. " ",
      title_pos = layout.labels and layout.labels.top and layout.labels.top.align or layout.title_pos,
    },
    height = list_height,
    width = width,
    total_height = height,
  }
  if layout.input_position == "bottom" then
    result.input = vim.tbl_extend("force", common, { row = row + height, height = 1 })
    result.list = vim.tbl_extend(
      "force",
      common,
      { row = row + 1 + (preview_height > 0 and preview_height + 1 or 0), height = list_height }
    )
    result.separators = { height - 2 }
    if preview_height > 0 then
      result.preview = vim.tbl_extend("force", common, { row = row + 1, height = preview_height, focusable = false })
      table.insert(result.separators, 1, preview_height)
    end
  else
    result.input = vim.tbl_extend("force", common, { row = row + 1, height = 1 })
    result.list = vim.tbl_extend("force", common, { row = row + 3, height = list_height })
    result.separators = { 1 }
    if preview_height > 0 then
      result.preview = vim.tbl_extend(
        "force",
        common,
        { row = row + height - preview_height + 1, height = preview_height, focusable = false }
      )
      result.separators[#result.separators + 1] = height - preview_height - 1
    end
  end
  return result
end

return M
