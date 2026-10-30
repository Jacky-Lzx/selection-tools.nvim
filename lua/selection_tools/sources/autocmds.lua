local util = require("selection_tools.sources.util")
return function()
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
  return {
    prompt = "Autocommands",
    finder = function(ctx)
      return util.collect(ctx, function(checkpoint)
        local items = {}
        for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
          -- Enumerating after mount must not expose the picker's own temporary events.
          if not (autocmd.group_name or ""):match("^SelectionTools%d+$") then
            items[#items + 1] = {
              autocmd = autocmd,
              key = table.concat({ autocmd.id or "", autocmd.event, autocmd.pattern or "" }, "\0"),
              text = ("%s %s %s  %s"):format(
                autocmd.event,
                autocmd.group_name or "",
                autocmd.pattern or "",
                autocmd.desc or autocmd.command or ""
              ),
            }
          end
          checkpoint()
        end
        table.sort(items, function(a, b)
          return a.text < b.text
        end)
        return items
      end)
    end,
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
