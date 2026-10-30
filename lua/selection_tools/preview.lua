local api, uv = vim.api, vim.uv
local focus_ns = api.nvim_create_namespace("selection_tools_preview_focus")
local Preview = {}
Preview.__index = Preview

function Preview.new(picker, buf)
  return setmetatable({ picker = picker, buf = buf, generation = 0 }, Preview)
end

function Preview:cancel()
  self.generation = self.generation + 1
  if self.cancel_provider then
    pcall(self.cancel_provider)
    self.cancel_provider = nil
  end
end

function Preview:_decorate(lines, pos)
  api.nvim_buf_clear_namespace(self.buf, focus_ns, 0, -1)
  if not pos or pos[1] < 1 or pos[1] > #lines or pos[1] > self.picker.opts.preview.max_lines then
    return
  end
  local row = pos[1] - 1
  if self.picker.opts.preview.highlight_line then
    api.nvim_buf_set_extmark(self.buf, focus_ns, row, 0, {
      end_row = row + 1,
      end_col = 0,
      hl_group = "SelectionToolsPreviewLine",
      hl_eol = true,
      priority = 90,
    })
  end
  local item, line = self.item, lines[row + 1]
  if not self.picker.opts.preview.highlight_matches or type(item) ~= "table" then
    return
  end
  local length = #line
  if item.code and item.code ~= line then
    local prefix = line:sub(-#"…") == "…" and line:sub(1, -#"…" - 1) or nil
    if not prefix or item.code:sub(1, #prefix) ~= prefix then
      return
    end
    length = #prefix
  end
  for _, range in ipairs(item.line_matches or {}) do
    local first, last = math.max(0, math.min(length, range[1])), math.max(0, math.min(length, range[2]))
    if first < last then
      api.nvim_buf_set_extmark(self.buf, focus_ns, row, first, {
        end_col = last,
        hl_group = "SelectionToolsPreviewMatch",
        priority = 200,
      })
    end
  end
end

function Preview:write(lines, ft, title, pos)
  if self.picker.closed or not api.nvim_buf_is_valid(self.buf) then
    return
  end
  if self.picker.preview_win and api.nvim_win_is_valid(self.picker.preview_win) then
    api.nvim_win_set_buf(self.picker.preview_win, self.buf)
  end
  if type(self.item) == "table" then
    ft = self.item.ft or ft
    if not pos and self.item.search then
      for row, line in ipairs(lines) do
        local col = line:find(self.item.search, 1, true)
        if col then
          pos = { row, col - 1 }
          break
        end
      end
    end
  end
  pcall(vim.treesitter.stop, self.buf)
  vim.bo[self.buf].modifiable = true
  api.nvim_buf_set_lines(self.buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].filetype = ft or ""
  vim.bo[self.buf].syntax = ft or ""
  if ft and ft ~= "" then
    local lang = vim.treesitter.language.get_lang(ft) or ft
    pcall(vim.treesitter.start, self.buf, lang)
  end
  if self.picker.preview_win and api.nvim_win_is_valid(self.picker.preview_win) then
    local row = math.max(1, math.min(pos and pos[1] or 1, api.nvim_buf_line_count(self.buf)))
    local line = api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] or ""
    api.nvim_win_set_cursor(self.picker.preview_win, { row, math.min(pos and pos[2] or 0, #line) })
    api.nvim_win_call(self.picker.preview_win, function()
      vim.cmd("normal! zz")
    end)
  end
  if ft == "diff" then
    require("selection_tools.diff").decorate(self.buf, lines)
  else
    api.nvim_buf_clear_namespace(self.buf, api.nvim_create_namespace("selection_tools_diff"), 0, -1)
  end
  self:_decorate(lines, pos)
  self.picker.preview_title = title or "Preview"
  self.displayed = true
  self.displayed_item = self.item
  self.picker:_restore_preview()
  self.picker:_draw_frame()
end

function Preview:update(item, index)
  local buf = type(item) == "table" and (item.bufnr or item.buf) or nil
  local tick = buf and api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_changedtick(buf) or nil
  if self.initialized and self.item == item and self.index == index and self.tick == tick then
    return
  end
  self:cancel()
  self.is_image = false
  self.initialized, self.item, self.index, self.tick = true, item, index, tick
  local generation = self.generation
  local function current()
    return not self.picker.closed and self.generation == generation
  end
  local function deliver(lines, ft, title, pos, decorate)
    vim.schedule(function()
      if current() then
        self:write(lines, ft, title, pos)
        if decorate and current() then
          decorate()
        end
      end
    end)
  end
  if not index then
    self:write({ "No preview" })
    return
  end
  local opts = self.picker.opts
  if opts.preview_item then
    local ok, result = pcall(opts.preview_item, item)
    if not ok then
      self:write({ "Preview error: " .. tostring(result):gsub("[\r\n]", " ") })
    elseif result and result.buf and api.nvim_buf_is_valid(result.buf) then
      -- Display caller buffers without copying highlights or changing their options.
      api.nvim_win_set_buf(self.picker.preview_win, result.buf)
      local row = math.max(1, math.min(result.pos and result.pos[1] or 1, api.nvim_buf_line_count(result.buf)))
      local line = api.nvim_buf_get_lines(result.buf, row - 1, row, false)[1] or ""
      api.nvim_win_set_cursor(self.picker.preview_win, { row, math.min(result.pos and result.pos[2] or 0, #line) })
      api.nvim_win_call(self.picker.preview_win, function()
        vim.cmd("normal! zz")
      end)
      self.picker.preview_title = "Preview"
      self.displayed = true
      self.displayed_item = self.item
      self.picker:_restore_preview()
      self.picker:_draw_frame()
    else
      self:write({ "No preview" })
    end
    return
  end
  if opts.previewer then
    local ok, cancel = pcall(opts.previewer, {
      item = item,
      index = index,
      buf = self.buf,
      win = self.picker.preview_win,
      is_cancelled = function()
        return not current()
      end,
      set_lines = deliver,
    })
    if not ok then
      self:write({ "Preview error: " .. tostring(cancel):gsub("[\r\n]", " ") })
    elseif type(cancel) == "function" then
      if current() then
        self.cancel_provider = cancel
      else
        pcall(cancel)
      end
    end
    return
  end
  local path = type(item) == "table" and item.file or nil
  if not buf and path then
    local known = vim.fn.bufnr(path)
    if known >= 0 and api.nvim_buf_is_loaded(known) then
      buf = known
    end
  end
  if buf and api.nvim_buf_is_loaded(buf) then
    local lines = api.nvim_buf_get_lines(buf, 0, opts.preview.max_lines, false)
    self:write(
      lines,
      vim.bo[buf].filetype,
      api.nvim_buf_get_name(buf) ~= "" and vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":t") or "[No Name]",
      type(item) == "table" and item.pos or nil
    )
    return
  end
  if not path then
    self:write({ "No file preview available" })
    return
  end
  if not path:match("^[/\\]") and not path:match("^%a:[/\\]") then
    path = vim.fs.joinpath(opts.cwd or vim.fn.getcwd(), path)
  end
  local image = opts.preview.image
  local ext = (path:match("%.([^%.]+)$") or ""):lower()
  if
    image ~= false
    and (not image or image.enabled ~= false)
    and vim.tbl_contains(
      { "png", "jpg", "jpeg", "gif", "bmp", "webp", "avif", "tif", "tiff", "heic", "svg", "pdf" },
      ext
    )
  then
    self.is_image = true
    self:write({ "Loading image…" }, nil, vim.fn.fnamemodify(path, ":t"))
    self.cancel_provider = require("selection_tools.image").render(path, type(image) == "table" and image or {}, {
      buf = self.buf,
      win = self.picker.preview_win,
      is_cancelled = function()
        return not current()
      end,
      write = function(lines, decorate)
        deliver(lines, nil, vim.fn.fnamemodify(path, ":t"), nil, decorate)
      end,
    })
    return
  end
  self.is_image = false
  local title = vim.fn.fnamemodify(path, ":t"):gsub("[\r\n]", " ")
  -- Keep the previous contents, highlighting and scroll position during I/O.
  -- Only the first preview needs a loading placeholder.
  if not self.displayed then
    self:write({ "Loading…" }, nil, title)
  end
  local ft = vim.filetype.match({ filename = path })
  uv.fs_open(path, "r", 438, function(open_err, fd)
    if not fd then
      deliver({ "Cannot preview file: " .. tostring(open_err):gsub("[\r\n]", " ") }, nil, title)
      return
    end
    if not current() then
      uv.fs_close(fd)
      return
    end
    uv.fs_fstat(fd, function(stat_err, stat)
      if not current() then
        uv.fs_close(fd)
        return
      end
      if not stat or stat.type ~= "file" then
        uv.fs_close(fd)
        deliver({ stat_err and tostring(stat_err) or "Preview requires a regular file" }, nil, title)
      elseif stat.size > opts.preview.max_size then
        uv.fs_close(fd)
        deliver(
          { ("File too large to preview (%d bytes; limit %d)"):format(stat.size, opts.preview.max_size) },
          nil,
          title
        )
      else
        uv.fs_read(fd, stat.size, 0, function(read_err, data)
          uv.fs_close(fd)
          if not current() then
            return
          end
          if read_err then
            deliver({ "Cannot read file: " .. tostring(read_err) }, nil, title)
          elseif data:find("\0", 1, true) then
            deliver({ ("Binary file (%d bytes)"):format(stat.size) }, nil, title)
          else
            local lines = vim.split(data:gsub("\r\n", "\n"), "\n", { plain = true })
            if #lines > 1 and lines[#lines] == "" then
              table.remove(lines)
            end
            local limited = {}
            for i = 1, math.min(#lines, opts.preview.max_lines) do
              limited[i] = #lines[i] > opts.preview.max_line_length
                  and (lines[i]:sub(1, opts.preview.max_line_length) .. "…")
                or lines[i]
            end
            if #lines > opts.preview.max_lines then
              limited[#limited + 1] = "… preview truncated"
            end
            deliver(limited, ft, title, type(item) == "table" and item.pos or nil)
          end
        end)
      end
    end)
  end)
end

return Preview
