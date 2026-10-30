local util = require("selection_tools.sources.util")

return function()
  local origin = util.capture()
  local list = vim.fn.getjumplist()
  local items = {}
  for i = #list[1], 1, -1 do
    local jump = list[1][i]
    if jump.lnum > 0 and vim.api.nvim_buf_is_valid(jump.bufnr) then
      local name = vim.api.nvim_buf_get_name(jump.bufnr)
      items[#items + 1] = {
        bufnr = jump.bufnr,
        file = name ~= "" and name or nil,
        pos = { jump.lnum, jump.col },
        jump_index = i - 1,
        text = ("%s%s:%d:%d"):format(
          i - 1 == list[2] and "> " or "  ",
          name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]",
          jump.lnum,
          jump.col + 1
        ),
      }
    end
  end
  return {
    prompt = "Jump list",
    items = items,
    resume_refresh = true,
    preview = { enabled = true },
    format_item = util.format,
    on_choice = function(item)
      if not item then
        return
      end
      util.context(origin, function()
        local current = vim.fn.getjumplist()[2]
        local delta = item.jump_index - current
        if delta ~= 0 then
          vim.cmd("normal! " .. math.abs(delta) .. (delta < 0 and "\015" or "\009"))
        end
      end)
    end,
  }
end
