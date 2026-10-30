local util = require("selection_tools.sources.util")
local uv = vim.uv
local M = {}
local files, merged = {}, nil

local function signature(stat)
  return table.concat(
    { stat.dev, stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec },
    ":"
  )
end

function M.load(ctx)
  local cancelled, cancels = false, {}
  local function current()
    return not cancelled and not ctx.is_cancelled()
  end
  local function schedule(fn)
    vim.schedule(function()
      if current() then
        fn()
      end
    end)
  end
  local function collect(produce, done)
    cancels[#cancels + 1] = util.collect({
      is_cancelled = function()
        return not current()
      end,
      fail = ctx.fail,
    }, produce, done)
  end
  local function begin()
    if not current() then
      return
    end
    local paths = vim.api.nvim_get_runtime_file("doc/tags", true)
    local active, results, pending = {}, {}, #paths
    for _, path in ipairs(paths) do
      active[path] = true
    end
    for path in pairs(files) do
      if not active[path] then
        files[path] = nil
      end
    end
    local function assemble()
      local keys = {}
      for _, path in ipairs(paths) do
        keys[#keys + 1] = path .. "\0" .. (results[path] and results[path].signature or "missing")
      end
      local key = table.concat(keys, "\0")
      collect(function(checkpoint)
        local templates
        if merged and merged.key == key then
          templates = merged.items
        else
          templates = {}
          local seen = {}
          for _, path in ipairs(paths) do
            for _, item in ipairs(results[path] and results[path].items or {}) do
              if not seen[item.tag] then
                seen[item.tag] = true
                templates[#templates + 1] = item
              end
              checkpoint()
            end
          end
          table.sort(templates, function(a, b)
            return a.tag < b.tag
          end)
          merged = { key = key, items = templates }
        end
        -- Cache private templates; callers receive independent item objects.
        local items = {}
        for i, item in ipairs(templates) do
          items[i] =
            { tag = item.tag, key = item.tag, text = item.text, file = item.file, search = item.search, ft = "help" }
          checkpoint()
        end
        return items
      end, function(items)
        ctx.set_items(items)
        ctx.done()
      end)
    end
    local function finish(path, entry)
      if not current() then
        return
      end
      files[path], results[path] = entry, entry
      pending = pending - 1
      if pending == 0 then
        assemble()
      end
    end
    if pending == 0 then
      assemble()
      return
    end
    for _, path in ipairs(paths) do
      uv.fs_stat(path, function(_, stat)
        if not current() then
          return
        end
        if not stat or stat.type ~= "file" then
          schedule(function()
            finish(path)
          end)
          return
        end
        local cached = files[path]
        if cached and cached.signature == signature(stat) then
          schedule(function()
            finish(path, cached)
          end)
          return
        end
        uv.fs_open(path, "r", 438, function(_, fd)
          if not fd then
            schedule(function()
              finish(path)
            end)
            return
          end
          if not current() then
            uv.fs_close(fd)
            return
          end
          uv.fs_fstat(fd, function(_, opened)
            if not opened or not current() then
              uv.fs_close(fd)
              schedule(function()
                finish(path)
              end)
              return
            end
            local chunks, offset = {}, 0
            local function read()
              uv.fs_read(fd, 131072, offset, function(err, data)
                if err or not current() then
                  uv.fs_close(fd)
                  schedule(function()
                    finish(path)
                  end)
                  return
                end
                if data and #data > 0 then
                  chunks[#chunks + 1], offset = data, offset + #data
                  read()
                  return
                end
                uv.fs_close(fd)
                schedule(function()
                  collect(function(checkpoint)
                    local items = {}
                    local directory = vim.fs.dirname(path)
                    for line in table.concat(chunks):gmatch("[^\r\n]+") do
                      local tag, file = line:match("^([^\t]+)\t([^\t]+)\t")
                      if tag and tag:sub(1, 1) ~= "!" then
                        items[#items + 1] = {
                          tag = tag,
                          text = tag .. "  " .. file,
                          file = vim.fs.joinpath(directory, file),
                          search = "*" .. tag .. "*",
                        }
                      end
                      checkpoint()
                    end
                    return items
                  end, function(items)
                    finish(path, { signature = signature(opened), items = items })
                  end)
                end)
              end)
            end
            read()
          end)
        end)
      end)
    end
  end
  local timer = vim.defer_fn(begin, 1)
  return function()
    cancelled = true
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    for _, cancel in ipairs(cancels) do
      cancel()
    end
    -- In-flight libuv reads close their descriptors in their callbacks.
  end
end

return M
