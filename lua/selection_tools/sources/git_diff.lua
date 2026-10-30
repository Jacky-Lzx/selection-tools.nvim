local git = require("selection_tools.git")
return function(opts)
  return {
    prompt = opts.staged and "Git staged changes" or "Git changes",
    cwd = opts.cwd or vim.fn.getcwd(),
    resume_refresh = true,
    multi = true,
    preview = { enabled = true },
    format_item = function(item)
      return item.text
    end,
    previewer = git.previewer(opts),
    finder = function(ctx)
      return git.root(ctx, function(root)
        local rename
        local function include(item)
          if opts.staged and not item.index_change then
            return
          end
          if opts.untracked == false and item.untracked then
            return
          end
          return item
        end
        return require("selection_tools.stream").start(
          git.command(root, { "status", "--porcelain=v1", "-z", "--untracked-files=all" }),
          {
            limit = opts.limit or 10000,
            separator = "\0",
            max_output = opts.max_output,
          },
          ctx,
          function(record)
            if rename then
              local item = rename
              rename = nil
              item.old_file = record
              return include(item)
            end
            local status, file = record:sub(1, 2), record:sub(4)
            assert(#status == 2 and record:sub(3, 3) == " " and file ~= "", "Invalid Git status record")
            local item = {
              root = root,
              relative_file = file,
              file = vim.fs.joinpath(root, file),
              pos = { 1, 0 },
              status = status,
              key = file,
              text = status .. " " .. file,
              untracked = status == "??",
              deleted = status:find("D", 1, true) ~= nil,
              index_change = status:sub(1, 1) ~= " " and status ~= "??",
              worktree_change = status:sub(2, 2) ~= " " and status ~= "??" and not opts.staged,
            }
            if status:find("[RC]") then
              rename = item
              return
            end
            return include(item)
          end
        )
      end)
    end,
    on_choice = function(item)
      if not item then
        return
      end
      if item.deleted then
        git.open_diff(item)
      else
        require("selection_tools.sources.util").jump(item)
      end
    end,
  }
end
