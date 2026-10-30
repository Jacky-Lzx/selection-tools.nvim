local util = require("selection_tools.sources.util")
local function plain(text)
  text = text:gsub("\27%[[%d;]*[A-Za-z]", "")
  while text:find("\b", 1, true) do
    local replaced, count = text:gsub("[^\128-\191\b][\128-\191]*\b", "")
    text = replaced
    if count == 0 then
      return text:gsub("\b", "")
    end
  end
  return text
end
return function(opts)
  return {
    prompt = "Man pages",
    format_item = util.format,
    resume_refresh = true,
    preview = { enabled = true },
    finder = function(ctx)
      local function scan(paths)
        local items, seen = {}, {}
        for _, root in ipairs(paths) do
          local stat = vim.uv.fs_stat(root)
          if stat and stat.type == "directory" then
            for dir, kind in vim.fs.dir(root) do
              if kind == "directory" and dir:match("^man[%w]+$") then
                for filename in vim.fs.dir(vim.fs.joinpath(root, dir)) do
                  local stem = filename:gsub("%.gz$", ""):gsub("%.bz2$", ""):gsub("%.xz$", ""):gsub("%.zst$", "")
                  local name, section = stem:match("^(.*)%.([%w]+)$")
                  local key = name and (name .. "(" .. section .. ")")
                  if key and not seen[key] then
                    seen[key] = true
                    items[#items + 1] = { name = name, section = section, text = key }
                  end
                end
              end
            end
          end
        end
        table.sort(items, function(a, b)
          return a.text < b.text
        end)
        ctx.set_items(items)
        ctx.done()
      end
      if opts.paths then
        scan(opts.paths)
        return
      end
      local command = vim.fn.executable("manpath") == 1 and { "manpath", "-q" } or { "man", "-w" }
      local job = vim.system(command, { text = true }, function(result)
        vim.schedule(function()
          if ctx.is_cancelled() then
            return
          end
          local paths = result.code == 0 and vim.trim(result.stdout)
            or (vim.env.MANPATH or "/usr/share/man:/usr/local/share/man")
          scan(vim.split(paths, ":", { plain = true, trimempty = true }))
        end)
      end)
      return function()
        pcall(job.kill, job, 15)
      end
    end,
    previewer = function(ctx)
      local job = vim.system({ opts.man_command or "man", ctx.item.section, ctx.item.name }, {
        text = true,
        env = {
          MANPAGER = "cat",
          PAGER = "cat",
          MANWIDTH = tostring(vim.api.nvim_win_get_width(ctx.win)),
          MAN_KEEP_FORMATTING = "1",
        },
      }, function(result)
        if result.code ~= 0 then
          ctx.set_lines(vim.split("Cannot render man page\n" .. (result.stderr or ""), "\n", { plain = true }))
          return
        end
        ctx.set_lines(vim.split(plain(result.stdout or ""), "\n", { plain = true }), "man", ctx.item.text)
      end)
      return function()
        pcall(job.kill, job, 15)
      end
    end,
    on_choice = function(item)
      if item then
        if vim.fn.exists(":Man") == 0 then
          vim.cmd("runtime plugin/man.lua")
        end
        vim.api.nvim_cmd({ cmd = "Man", args = { item.section, item.name }, magic = { bar = false } }, {})
      end
    end,
  }
end
