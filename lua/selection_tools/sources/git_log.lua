local git = require("selection_tools.git")
return function(opts)
  return {
    prompt = "Git log",
    cwd = opts.cwd or vim.fn.getcwd(),
    resume_refresh = true,
    preview = { enabled = true },
    format_item = function(item)
      return item.text
    end,
    previewer = git.previewer(opts),
    finder = function(ctx)
      return git.root(ctx, function(root)
        local cancel
        local check = vim.system(
          git.command(root, { "rev-parse", "--verify", "HEAD" }),
          {},
          vim.schedule_wrap(function(result)
            if ctx.is_cancelled() then
              return
            end
            if result.code ~= 0 then
              ctx.done()
              return
            end
            local args =
              { "log", "--date=short", "--format=%H%x1f%an%x1f%ad%x1f%s%x00", "--max-count=" .. (opts.limit or 200) }
            if opts.all then
              args[#args + 1] = "--all"
            end
            if opts.file then
              vim.list_extend(args, { "--", opts.file })
            end
            cancel = require("selection_tools.stream").start(
              git.command(root, args),
              {
                limit = opts.limit or 200,
                separator = "\0",
                max_output = opts.max_output,
              },
              ctx,
              function(record)
                record = record:gsub("^\n", "")
                if record == "" then
                  return
                end
                local sha, author, date, subject = record:match("^([%x]+)\31(.-)\31(.-)\31(.*)$")
                assert(sha, "Invalid Git log record")
                return {
                  commit = sha,
                  root = root,
                  key = sha,
                  text = sha:sub(1, 8) .. " " .. date .. " " .. author .. " · " .. subject,
                }
              end
            )
          end)
        )
        return function()
          if cancel then
            cancel()
          end
          if not check:is_closing() then
            pcall(check.kill, check, 15)
          end
        end
      end)
    end,
    on_choice = git.open_diff,
  }
end
