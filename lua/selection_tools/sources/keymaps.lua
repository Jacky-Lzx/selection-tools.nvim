local util = require("selection_tools.sources.util")
return function(opts)
  local origin = util.capture()
  local definition = util.definitions()
  local function describe(item)
    if item.detail then
      return
    end
    local map = item.map
    local location = definition(map.callback, map.sid, map.lnum)
    if location then
      item.file, item.pos = location.file, location.pos
    end
    item.detail, item.ft = vim.inspect(map), "lua"
  end
  return {
    prompt = "Keymaps",
    finder = function(ctx)
      return util.collect(ctx, function(checkpoint)
        local maps = {}
        for _, mode in ipairs(opts.modes or { "n", "v", "x", "s", "o", "i", "c", "t" }) do
          local function add(list, scope)
            for _, map in ipairs(list) do
              if opts.plugs or not map.lhs:match("^<Plug>") then
                local item = { key = mode .. "\0" .. map.lhs }
                item.lhs, item.mode, item.map = map.lhs, mode, map
                item.text = ("%s %s  %s  %s  %s"):format(mode, map.lhs, scope, map.desc or "", map.rhs or "")
                maps[mode .. "\0" .. map.lhs] = item
              end
              checkpoint()
            end
          end
          if opts.global ~= false then
            add(vim.api.nvim_get_keymap(mode), "global")
          end
          if opts["local"] ~= false then
            add(vim.api.nvim_buf_get_keymap(origin.buf, mode), "buffer")
          end
        end
        local items = vim.tbl_values(maps)
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
      if not item then
        return
      end
      util.context(origin, function()
        if opts.action == "definition" then
          describe(item)
          if item.file then
            util.jump(item)
          else
            util.show(item)
          end
        else
          -- Match the previous Snacks action: replay the selected keys in Normal mode.
          local keys = vim.api.nvim_replace_termcodes(item.lhs, true, false, true)
          vim.api.nvim_feedkeys(keys, "mt", false)
        end
      end)
    end,
  }
end
