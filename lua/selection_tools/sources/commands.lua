local util = require("selection_tools.sources.util")
return function(opts)
  local origin, by_name = util.capture(), {}
  for _, name in ipairs(vim.fn.getcompletion("", "command")) do
    by_name[name] =
      { name = name, text = name, detail = ":" .. name .. "\nBuilt-in command; see :help :" .. name, ft = "vim" }
  end
  local function add(commands, scope)
    for name, cmd in pairs(commands) do
      by_name[name] = {
        name = name,
        key = name,
        text = name .. "  " .. scope .. "  " .. (cmd.definition or ""),
        ft = "vim",
        command = cmd,
        scope = scope,
      }
    end
  end
  add(vim.api.nvim_get_commands({ builtin = false }), "global")
  add(vim.api.nvim_buf_get_commands(origin.buf, { builtin = false }), "buffer")
  local items = vim.tbl_values(by_name)
  table.sort(items, function(a, b)
    return a.name < b.name
  end)
  return {
    prompt = "Commands",
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    previewer = function(ctx)
      local item = ctx.item
      if not item.detail then
        item.detail = vim.inspect(vim.tbl_extend("force", { scope = item.scope }, item.command))
      end
      util.preview(ctx)
    end,
    on_choice = function(item)
      if item then
        util.context(origin, function()
          if opts.execute then
            vim.api.nvim_cmd({ cmd = item.name }, {})
          else
            vim.api.nvim_feedkeys(":" .. item.name .. " ", "n", false)
          end
        end)
      end
    end,
  }
end
