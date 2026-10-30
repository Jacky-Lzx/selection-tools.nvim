local util = require("selection_tools.sources.util")
return function()
  local items = {}
  local definition = util.definitions()
  local function describe(item)
    if item.detail then
      return
    end
    local location = definition(item.autocmd.callback)
    if location then
      item.file, item.pos = location.file, location.pos
    end
    item.detail, item.ft = vim.inspect(item.autocmd), "lua"
  end
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    local item =
      { autocmd = autocmd, key = table.concat({ autocmd.id or "", autocmd.event, autocmd.pattern or "" }, "\0") }
    item.text = ("%s %s %s  %s"):format(
      autocmd.event,
      autocmd.group_name or "",
      autocmd.pattern or "",
      autocmd.desc or autocmd.command or ""
    )
    items[#items + 1] = item
  end
  table.sort(items, function(a, b)
    return a.text < b.text
  end)
  return {
    prompt = "Autocommands",
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    previewer = function(ctx)
      describe(ctx.item)
      util.preview(ctx)
    end,
    on_choice = function(item)
      if item then
        describe(item)
        if item.file then
          util.jump(item)
        else
          util.show(item)
        end
      end
    end,
  }
end
