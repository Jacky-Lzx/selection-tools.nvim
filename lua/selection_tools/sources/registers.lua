local util = require("selection_tools.sources.util")

return function(opts)
  local items = {}
  local registers = opts.registers or '*+"-:.%/#=abcdefghijklmnopqrstuvwxyz0123456789'
  local clipboard = vim.g.clipboard
  for i = 1, #registers do
    local name = registers:sub(i, i)
    local skip = name:match("[%+%*]")
      and not opts.registers
      and ((clipboard and clipboard.name == "OSC 52") or (not clipboard and vim.g.loaded_clipboard_provider ~= 2))
    if not skip then
      local ok, lines = pcall(vim.fn.getreg, name, 1, true)
      if ok and table.concat(lines, "\n") ~= "" then
        items[#items + 1] = {
          key = name,
          name = name,
          lines = lines,
          value = table.concat(lines, "\n"),
          regtype = vim.fn.getregtype(name),
          text = name .. ": " .. table.concat(lines, "\\n"),
          ft = "text",
        }
      end
    end
  end
  return {
    prompt = "Registers",
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    previewer = util.preview,
    on_choice = function(item)
      if item then
        vim.fn.setreg(opts.register or "+", item.lines, item.regtype)
      end
    end,
  }
end
