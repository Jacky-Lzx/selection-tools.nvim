local util = require("selection_tools.sources.util")

return function(opts)
  local target = util.file_window()
  local cwd = vim.fn.fnamemodify(opts.cwd or vim.fn.getcwd(), ":p")
  return {
    prompt = "Files",
    multi = true,
    search_options = true,
    preview = { enabled = true },
    cwd = cwd,
    components = not opts.format_item and {
      require("selection_tools.components").icon(),
      require("selection_tools.components").path({ field = "text", path_format = false }),
    } or nil,
    format_item = function(item)
      return item.text
    end,
    finder = function(ctx)
      local opts, cwd = ctx.opts, ctx.cwd
      local cmd
      if vim.fn.executable("fd") == 1 and #(opts.globs or {}) == 0 then
        cmd = { "fd", "--type", "f", "--color", "never", "--print0", "--exclude", ".git" }
        if opts.hidden then
          cmd[#cmd + 1] = "--hidden"
        end
        if opts.ignored then
          cmd[#cmd + 1] = "--no-ignore"
        end
      elseif vim.fn.executable("rg") == 1 then
        cmd = { "rg", "--files", "--null", "--glob", "!.git/**" }
        if opts.hidden then
          cmd[#cmd + 1] = "--hidden"
        end
        if opts.ignored then
          cmd[#cmd + 1] = "--no-ignore"
        end
      else
        ctx.fail("file search requires fd or ripgrep (rg)")
        return
      end
      for _, glob in ipairs(opts.globs or {}) do
        vim.list_extend(cmd, { "--glob", glob })
      end
      local process = vim.system(cmd, { cwd = cwd }, function(result)
        if ctx.is_cancelled() then
          return
        end
        if result.code ~= 0 and not (result.code == 1 and result.stderr == "") then
          ctx.fail(result.stderr ~= "" and result.stderr or ("file search exited with code " .. result.code))
          return
        end
        local paths = vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })
        table.sort(paths)
        local items = {}
        for _, path in ipairs(paths) do
          path = path:gsub("^%./", "")
          items[#items + 1] = { text = path, file = vim.fs.joinpath(cwd, path) }
        end
        ctx.set_items(items)
        ctx.done()
      end)
      return function()
        if not process:is_closing() then
          process:kill(15)
        end
      end
    end,
    on_choice = function(item, _, selected)
      if item then
        -- bufadd avoids Ex parsing for spaces, bars, percent signs and newlines.
        local buffers = {}
        for _, value in ipairs(selected or { item }) do
          local buf = vim.fn.bufadd(value.file)
          vim.bo[buf].buflisted = true
          buffers[#buffers + 1] = buf
        end
        util.focus_file_window(target)
        vim.api.nvim_set_current_buf(buffers[1])
      end
    end,
  }
end
