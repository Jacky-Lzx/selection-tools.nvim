local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("selection_tools_diff")
function M.decorate(buf, lines)
  for name, link in pairs({ Add = "Added", Delete = "Removed", Hunk = "Title", Header = "Comment" }) do
    api.nvim_set_hl(0, "SelectionToolsDiff" .. name, { default = true, link = link })
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local kind
    if line:match("^+++ ") or line:match("^%-%-%- ") or line:match("^diff ") or line:match("^index ") then
      kind = "Header"
    elseif line:match("^@@") or line:match("^commit ") then
      kind = "Hunk"
    elseif line:sub(1, 1) == "+" then
      kind = "Add"
    elseif line:sub(1, 1) == "-" then
      kind = "Delete"
    end
    if kind then
      api.nvim_buf_set_extmark(
        buf,
        ns,
        i - 1,
        0,
        { end_col = #line, hl_group = "SelectionToolsDiff" .. kind, priority = 120 }
      )
    end
  end
end
return M
