local util = require("selection_tools.sources.util")
local catalogs = {
  nerd_fonts = {
    url = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts/master/glyphnames.json",
    build = function(data)
      local items = {}
      for name, info in pairs(data) do
        if type(info) == "table" and info.char then
          local category, label = name:match("^([%w_]+)%-(.*)$")
          items[#items + 1] = { icon = info.char, name = label or name, category = category, source = "nerd fonts" }
        end
      end
      return items
    end,
  },
  emoji = {
    url = "https://raw.githubusercontent.com/muan/unicode-emoji-json/main/data-by-emoji.json",
    build = function(data)
      local items = {}
      for icon, info in pairs(data) do
        items[#items + 1] = { icon = icon, name = info.name, category = info.group, source = "emoji" }
      end
      return items
    end,
  },
}
local builtin = {
  { icon = "✓", name = "check" },
  { icon = "✗", name = "cross" },
  { icon = "→", name = "arrow right" },
  { icon = "←", name = "arrow left" },
  { icon = "★", name = "star" },
  { icon = "λ", name = "lambda" },
  { icon = "⚠", name = "warning" },
  { icon = "♥", name = "heart" },
}
return function(opts)
  local origin = util.capture()
  return {
    prompt = "Icons",
    format_item = util.format,
    resume_refresh = true,
    preview = { enabled = true },
    previewer = util.preview,
    finder = function(ctx)
      local items, seen, jobs, pending = {}, {}, {}, 0
      local function add(list, source)
        for _, icon in ipairs(list) do
          local glyph, name = icon.icon or icon[1], icon.name or icon[2] or ""
          local category = icon.category or ""
          local key = glyph and (glyph .. "\0" .. name .. "\0" .. source)
          if key and not seen[key] then
            seen[key] = true
            items[#items + 1] = {
              key = key,
              icon = glyph,
              name = name,
              text = table.concat({ glyph, icon.source or source, category, name }, "  "),
              detail = glyph .. "\n\n" .. name .. "\n" .. category .. "\n" .. (icon.source or source),
            }
          end
        end
        table.sort(items, function(a, b)
          return a.text < b.text
        end)
        ctx.set_items(vim.list_slice(items))
      end
      if opts.icons then
        add(opts.icons, "custom")
        ctx.done()
        return
      end
      add(builtin, "symbols")
      if opts.devicons ~= false then
        local shared = package.loaded["theme_tools.icons"]
        if type(shared) == "table" and type(shared.catalog) == "function" then
          add(shared.catalog(), "theme-tools")
        else
          local ok, devicons = pcall(require, "nvim-web-devicons")
          if ok then
            local list = {}
            for name, icon in pairs(devicons.get_icons()) do
              list[#list + 1] = { icon = icon.icon, name = icon.name or name }
            end
            add(list, "devicons")
          end
        end
      end
      local sources = {}
      for _, name in ipairs(opts.icon_sources or { "nerd_fonts", "emoji" }) do
        assert(catalogs[name], "selection-tools: unknown icon catalog: " .. name)
        sources[name] = catalogs[name]
      end
      for name, path in pairs(opts.custom_sources or {}) do
        sources[name] = { url = path }
      end
      local cache = vim.fs.joinpath(vim.fn.stdpath("cache"), "selection-tools", "icons")
      local function finish()
        pending = pending - 1
        if pending == 0 then
          ctx.done()
        end
      end
      for _ in pairs(sources) do
        pending = pending + 1
      end
      if pending == 0 then
        ctx.done()
        return
      end
      for name, source in pairs(sources) do
        local remote = source.url:match("^https?://")
        local path = remote
            and vim.fs.joinpath(
              cache,
              name:gsub("[^%w_-]", "_") .. "-" .. vim.fn.sha256(source.url):sub(1, 8) .. ".json"
            )
          or source.url
        local function decode(text, save)
          local ok, data = pcall(vim.json.decode, text)
          local built, list = false, nil
          if ok then
            built, list = pcall(source.build or function(value)
              return value
            end, data)
          end
          if built and type(list) == "table" then
            add(list, name)
            if save then
              vim.fn.mkdir(cache, "p")
              pcall(vim.fn.writefile, { text }, path)
            end
          else
            vim.notify("selection-tools: invalid icon catalog " .. name, vim.log.levels.WARN)
          end
          finish()
        end
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok then
          decode(table.concat(lines, "\n"))
        elseif remote and vim.fn.executable("curl") == 1 then
          local started, job = pcall(
            vim.system,
            { "curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "20", source.url },
            { text = true },
            function(result)
              vim.schedule(function()
                if ctx.is_cancelled() then
                  return
                end
                if result.code == 0 then
                  decode(result.stdout, true)
                else
                  vim.notify(
                    "selection-tools: cannot fetch " .. name .. " icons: " .. vim.trim(result.stderr or ""),
                    vim.log.levels.WARN
                  )
                  finish()
                end
              end)
            end
          )
          if started then
            jobs[#jobs + 1] = job
          else
            vim.notify("selection-tools: cannot fetch " .. name .. " icons: " .. tostring(job), vim.log.levels.WARN)
            finish()
          end
        else
          vim.notify("selection-tools: cannot read icon catalog " .. name, vim.log.levels.WARN)
          finish()
        end
      end
      return function()
        for _, job in ipairs(jobs) do
          pcall(job.kill, job, 15)
        end
      end
    end,
    on_choice = function(item)
      if item then
        util.context(origin, function()
          vim.api.nvim_put({ item.icon }, "c", true, true)
        end, true)
      end
    end,
  }
end
