local M = {}
local api = vim.api

-- One optional provider per picker. Cached results live on entries, so replaced
-- live-search candidates (and their icons) can be garbage-collected together.
function M.new(opts)
  local provider, warned
  local function devicons()
    if provider == nil then
      local ok, value = pcall(require, "nvim-web-devicons")
      provider = ok and type(value) == "table" and value or false
    end
    return provider
  end
  local function automatic(item)
    if type(item) ~= "table" then
      return
    end
    if item.dir then
      return "󰉋", "SelectionToolsDirectoryIcon"
    end
    local file, ft = item.file, nil
    local buf = item.bufnr or item.buf
    if type(buf) == "number" and api.nvim_buf_is_valid(buf) then
      file = file or api.nvim_buf_get_name(buf)
      ft = vim.bo[buf].filetype
    end
    if (not file or file == "") and not buf then
      return
    end
    local name = file and vim.fs.basename(file) or ""
    local icons = devicons()
    if icons then
      local ok, icon, hl
      if name ~= "" and type(icons.get_icon) == "function" then
        -- nil extension preserves exact filenames and compound extensions.
        ok, icon, hl = pcall(icons.get_icon, name, nil, { default = false, strict = true })
        if ok and icon then
          return icon, hl
        end
      end
      if ft and ft ~= "" and type(icons.get_icon_by_filetype) == "function" then
        ok, icon, hl = pcall(icons.get_icon_by_filetype, ft, { default = false })
        if ok and icon then
          return icon, hl
        end
      end
      if type(icons.get_icon) == "function" then
        ok, icon, hl = pcall(icons.get_icon, name, nil, { default = true, strict = true })
        if ok and icon then
          return icon, hl
        end
      end
    end
    return "󰈙", "SelectionToolsFileIcon"
  end
  return function(entry)
    if not entry.icon_resolved then
      entry.icon_resolved = true
      local icon, hl
      if opts.format_icon then
        local ok
        ok, icon, hl = pcall(opts.format_icon, entry.item, entry.index)
        if not ok then
          if not warned then
            warned = true
            vim.notify("selection-tools: icon formatter failed: " .. tostring(icon), vim.log.levels.WARN)
          end
          icon = nil
        end
      else
        icon, hl = automatic(entry.item)
      end
      if type(icon) == "string" and icon ~= "" then
        icon = icon:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "  "):gsub("%z", "\\0")
        entry.icon = { text = icon, hl = type(hl) == "string" and hl ~= "" and hl or "SelectionToolsFileIcon" }
      end
    end
    return entry.icon
  end
end

return M
