local api, uv = vim.api, vim.uv
local Syntax = {}
Syntax.__index = Syntax

local function stamp(stat)
  return table.concat(
    { stat.dev, stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec },
    ":"
  )
end
local function dispose(doc)
  if doc and doc.parser then
    pcall(doc.parser.destroy, doc.parser)
    doc.parser = nil
  end
end
local function range4(range)
  if #range == 6 then
    return range[1], range[2], range[4], range[5]
  end
  return range[1], range[2], range[3], range[4]
end

function Syntax.new(picker)
  return setmetatable({ picker = picker, opts = picker.opts.syntax, files = {}, pending = {}, clock = 0 }, Syntax)
end
function Syntax:_redraw()
  if self.redraw_pending or self.closed then
    return
  end
  self.redraw_pending = true
  vim.schedule(function()
    self.redraw_pending = false
    if not self.closed and not self.picker.closed then
      self.picker:_render()
    end
  end)
end
function Syntax:_finish(job, doc)
  if self.closed or self.picker.closed or self.pending[job.path] ~= job then
    dispose(doc)
    return
  end
  self.pending[job.path] = nil
  local old = self.files[job.path]
  if old ~= doc then
    dispose(old)
  end
  doc.version, doc.used = job.version, job.used
  self.files[job.path] = doc
  while vim.tbl_count(self.files) > math.max(self.opts.cache_size, self.picker.height) do
    local oldest, age
    for path, cached in pairs(self.files) do
      if not age or cached.used < age then
        oldest, age = path, cached.used
      end
    end
    dispose(self.files[oldest])
    self.files[oldest] = nil
  end
  self:_redraw()
end
function Syntax:_load(path, buf, tick, version, old)
  local job = { path = path, version = version, used = self.clock }
  self.pending[path] = job
  local function current()
    return not self.closed and not self.picker.closed and self.pending[path] == job
  end
  local function finish(doc)
    vim.schedule(function()
      self:_finish(job, doc or {})
    end)
  end
  local function parse(text, ft, signature)
    if not current() then
      return
    end
    if #text > self.opts.max_size or text:find("\0", 1, true) then
      finish()
      return
    end
    local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
    if #lines > 1 and lines[#lines] == "" then
      table.remove(lines)
    end
    if #lines > self.opts.max_lines then
      finish()
      return
    end
    text = text:gsub("\r\n", "\n")
    local lang = ft and (vim.treesitter.language.get_lang(ft) or ft)
    if not lang or lang == "" then
      finish()
      return
    end
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok then
      finish()
      return
    end
    local doc = { parser = parser, text = text, lines = lines, signature = signature, rows = {} }
    local completed = false
    local function parsed(err)
      if completed then
        return
      end
      completed = true
      if err or not current() then
        dispose(doc)
        if current() then
          finish()
        end
      else
        finish(doc)
      end
    end
    -- New Neovim versions can yield parsing; older versions return trees synchronously.
    local parsed_ok, trees = pcall(parser.parse, parser, true, function(err)
      vim.schedule(function()
        parsed(err)
      end)
    end)
    if not parsed_ok then
      parsed_ok, trees = pcall(parser.parse, parser)
    end
    if not parsed_ok then
      parsed(trees)
    elseif trees then
      parsed()
    end
  end
  job.timer = vim.defer_fn(function()
    if not current() then
      return
    end
    if buf and not api.nvim_buf_is_valid(buf) then
      finish()
      return
    end
    local ft = buf and vim.bo[buf].filetype
    if not ft or ft == "" then
      ft = vim.filetype.match({ filename = path })
    end
    if buf then
      if api.nvim_buf_get_changedtick(buf) ~= tick then
        finish()
        return
      end
      local count = api.nvim_buf_line_count(buf)
      if count > self.opts.max_lines or api.nvim_buf_get_offset(buf, count) > self.opts.max_size then
        finish()
        return
      end
      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      parse(table.concat(lines, "\n") .. (vim.bo[buf].endofline and "\n" or ""), ft)
      return
    end
    uv.fs_stat(path, function(_, stat)
      if not current() then
        return
      end
      if not stat or stat.type ~= "file" or stat.size > self.opts.max_size then
        finish()
        return
      end
      if old and old.parser and old.signature == stamp(stat) then
        finish(old)
        return
      end
      uv.fs_open(path, "r", 438, function(_, fd)
        if not fd then
          finish()
          return
        end
        if not current() then
          uv.fs_close(fd)
          return
        end
        uv.fs_fstat(fd, function(_, opened)
          if not opened or not current() then
            uv.fs_close(fd)
            if current() then
              finish()
            end
            return
          end
          local chunks, offset = {}, 0
          local function read()
            uv.fs_read(fd, 131072, offset, function(err, data)
              if err or not current() then
                uv.fs_close(fd)
                if current() then
                  finish()
                end
                return
              end
              if data and #data > 0 then
                chunks[#chunks + 1], offset = data, offset + #data
                if offset > self.opts.max_size then
                  uv.fs_close(fd)
                  finish()
                  return
                end
                read()
                return
              end
              uv.fs_close(fd)
              vim.schedule(function()
                parse(table.concat(chunks), ft, stamp(opened))
              end)
            end)
          end
          read()
        end)
      end)
    end)
  end, 1)
end

function Syntax:_row(doc, item)
  local row = item.pos[1] - 1
  if not doc.parser or doc.lines[row + 1] ~= item.code then
    return
  end
  if not doc.rows[row] then
    local spans = {}
    local ok = pcall(function()
      doc.parser:for_each_tree(function(tree, language_tree)
        local lang = language_tree:lang()
        local query = vim.treesitter.query.get(lang, "highlights")
        if not query then
          return
        end
        local regions = tree:included_ranges(true)
        for id, node, metadata in query:iter_captures(tree:root(), doc.text, row, row + 1) do
          metadata = metadata or {}
          local name = query.captures[id]
          if name and name:sub(1, 1) ~= "_" then
            local sr, sc, er, ec = range4(vim.treesitter.get_range(node, doc.text, metadata[id]))
            if sr <= row and er >= row then
              local first, last = sr == row and sc or 0, er == row and ec or #item.code
              for _, region in ipairs(regions) do
                local rs, cs, re, ce = range4(region)
                if rs <= row and re >= row then
                  local start = math.max(first, rs == row and cs or 0)
                  local finish = math.min(last, re == row and ce or #item.code)
                  if start < finish then
                    spans[#spans + 1] = {
                      start,
                      finish,
                      hl = "@" .. name .. "." .. lang,
                      priority = math.min(
                        109,
                        tonumber(metadata.priority or metadata[id] and metadata[id].priority) or 100
                      ),
                    }
                  end
                end
              end
            end
          end
        end
      end)
    end)
    doc.rows[row] = ok and spans or {}
  end
  local spans = doc.rows[row]
  return spans
end
-- nil means preparation is pending; an empty list is a ready plain-text fallback.
function Syntax:highlights(item)
  local path = item.file
  self.clock = self.clock + 1
  local buf = item.bufnr or vim.fn.bufnr(path)
  if buf < 0 or not api.nvim_buf_is_loaded(buf) then
    buf = nil
  end
  local tick = buf and api.nvim_buf_get_changedtick(buf)
  local version = buf and ("buffer:" .. buf .. ":" .. tick) or ("disk:" .. self.picker.generation)
  local doc = self.files[path]
  if doc then
    doc.used = self.clock
  end
  if doc and doc.version == version then
    doc.used = self.clock
    return self:_row(doc, item) or {}
  end
  local job = self.pending[path]
  if not job or job.version ~= version then
    self:_load(path, buf, tick, version, doc)
  else
    job.used = self.clock
  end
  -- Revalidate snapshots in the background without stripping existing colors.
  -- _row only reuses spans when the candidate still has the exact same code.
  return doc and self:_row(doc, item)
end
function Syntax:close()
  self.closed = true
  for _, job in pairs(self.pending) do
    if job.timer and not job.timer:is_closing() then
      job.timer:stop()
      job.timer:close()
    end
  end
  for _, doc in pairs(self.files) do
    dispose(doc)
  end
  self.files, self.pending = {}, {}
end
return Syntax
