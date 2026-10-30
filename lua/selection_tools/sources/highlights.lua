local util = require("selection_tools.sources.util")
local ns = vim.api.nvim_create_namespace("selection_tools_highlights")
return function()
  local items = {}
  for _, name in ipairs(vim.fn.getcompletion("", "highlight")) do
    items[#items + 1] = { name = name, key = name, text = name }
  end
  return {
    prompt = "Highlights",
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    previewer = function(ctx)
      local name = ctx.item.name
      local lines = vim.split(
        table.concat({
          "Sample: AaBbCc 0123456789 !@#$%",
          "",
          name,
          "",
          vim.inspect(vim.api.nvim_get_hl(0, { name = name, link = true, create = false })),
          "",
          "Resolved:",
          vim.inspect(vim.api.nvim_get_hl(0, { name = name, link = false, create = false })),
        }, "\n"),
        "\n",
        { plain = true }
      )
      ctx.set_lines(lines, "text", name)
      vim.schedule(function()
        if ctx.is_cancelled() or not vim.api.nvim_buf_is_valid(ctx.buf) then
          return
        end
        vim.api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(ctx.buf, ns, 0, 0, { end_row = 0, end_col = #lines[1], hl_group = ctx.item.name })
      end)
    end,
  }
end
