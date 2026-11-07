local util = require("selection_tools.sources.util")

return function(opts)
  local cwd = vim.fn.getcwd()
  return {
    prompt = "Projects",
    resume_refresh = true,
    finder = function(ctx)
      return util.collect(ctx, function(checkpoint)
        local items, seen, roots = {}, {}, {}
        local markers = opts.markers
          or { ".git", ".hg", ".svn", "Cargo.toml", "package.json", "pyproject.toml", "flake.nix", "Makefile" }
        local function add(path)
          path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
          path = vim.uv.fs_realpath(path) or path
          local stat = vim.uv.fs_stat(path)
          if stat and stat.type == "directory" and not seen[path] then
            seen[path] = true
            items[#items + 1] = { dir = path, key = path, text = vim.fn.fnamemodify(path, ":~") }
          end
        end
        local function project(path)
          local directory = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
          if roots[directory] == nil then
            roots[directory] = vim.fs.root(directory, markers) or false
          end
          if roots[directory] then
            add(roots[directory])
          end
        end
        add(vim.fs.root(cwd, markers) or cwd)
        for _, path in ipairs(opts.projects or {}) do
          add(path)
          checkpoint()
        end
        if opts.recent ~= false then
          for _, path in ipairs(vim.v.oldfiles) do
            project(path)
            checkpoint()
          end
          for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
            if info.name ~= "" then
              project(info.name)
            end
            checkpoint()
          end
        end
        local dev = type(opts.dev) == "string" and { opts.dev } or opts.dev or { "~/dev", "~/projects" }
        for _, root in ipairs(dev) do
          root = vim.fn.expand(root)
          if vim.fn.isdirectory(root) == 1 then
            for name, kind in vim.fs.dir(root, { depth = opts.max_depth or 2 }) do
              if vim.tbl_contains(markers, vim.fs.basename(name)) then
                add(vim.fs.dirname(vim.fs.joinpath(root, name)))
              end
              checkpoint()
            end
          end
        end
        return items
      end)
    end,
    components = not opts.format_item and {
      require("selection_tools.components").icon(),
      require("selection_tools.components").path({ field = "text", path_format = false }),
    } or nil,
    format_item = util.format,
    preview = { enabled = true },
    previewer = function(ctx)
      local lines = { ctx.item.dir, "" }
      local ok, err = pcall(function()
        local names = {}
        for name, kind in vim.fs.dir(ctx.item.dir) do
          names[#names + 1] = name .. (kind == "directory" and "/" or "")
          if #names >= 200 then
            break
          end
        end
        table.sort(names)
        vim.list_extend(lines, names)
      end)
      if not ok then
        lines[#lines + 1] = tostring(err)
      end
      ctx.set_lines(lines, "text", "Project")
    end,
    on_choice = function(item)
      if not item then
        return
      end
      vim.api.nvim_set_current_dir(item.dir)
      if opts.open_files ~= false then
        require("selection_tools").files(vim.tbl_extend("force", {}, opts.files or {}, { cwd = item.dir }))
      end
    end,
  }
end
