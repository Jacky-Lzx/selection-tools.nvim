local M = {}
local api = vim.api

function M.path(path, cwd)
  if path:match("^[/\\]") or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(cwd or vim.fn.getcwd(), path))
end

function M.jump(item)
  if not item then
    return
  end
  local buf = item.bufnr or (item.file and vim.fn.bufadd(item.file))
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  vim.cmd("normal! m'")
  vim.bo[buf].buflisted = true
  api.nvim_set_current_buf(buf)
  if item.pos then
    local row = math.max(1, math.min(item.pos[1], api.nvim_buf_line_count(buf)))
    local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    api.nvim_win_set_cursor(0, { row, math.max(0, math.min(item.pos[2] or 0, #line)) })
    vim.cmd("normal! zvzz")
  end
end

function M.format(item)
  return item.text
end

function M.location(file, row, col, text, cwd)
  return {
    file = M.path(file, cwd),
    pos = { row, col },
    text = ("%s:%d:%d: %s"):format(file, row, col + 1, (text or ""):gsub("[\r\n]+$", "")),
  }
end

function M.capture()
  return {
    win = api.nvim_get_current_win(),
    buf = api.nvim_get_current_buf(),
    cursor = api.nvim_win_get_cursor(0),
    tick = api.nvim_buf_get_changedtick(0),
    mode = api.nvim_get_mode().mode,
  }
end

function M.context(origin, fn, unchanged)
  if
    not api.nvim_win_is_valid(origin.win)
    or not api.nvim_buf_is_valid(origin.buf)
    or api.nvim_win_get_buf(origin.win) ~= origin.buf
    or (unchanged and api.nvim_buf_get_changedtick(origin.buf) ~= origin.tick)
  then
    vim.notify("selection-tools: original buffer or window changed", vim.log.levels.WARN)
    return
  end
  return api.nvim_win_call(origin.win, fn)
end

function M.preview(ctx)
  local item = ctx.item
  ctx.set_lines(
    item.lines or vim.split(item.detail or item.text or "", "\n", { plain = true }),
    item.ft or "text",
    item.text
  )
end

function M.rg(opts, ctx, pattern, transform)
  local process, timer
  local function start()
    timer = nil
    if ctx.is_cancelled() then
      return
    end
    if vim.fn.executable(opts.command or "rg") ~= 1 then
      ctx.fail("search requires ripgrep (rg)")
      return
    end
    local cmd = { opts.command or "rg", "--json", "--smart-case", "--color", "never", "--glob", "!.git/**" }
    if opts.regex ~= true then
      cmd[#cmd + 1] = "--fixed-strings"
    end
    if opts.hidden then
      cmd[#cmd + 1] = "--hidden"
    end
    if opts.ignored then
      cmd[#cmd + 1] = "--no-ignore"
    end
    vim.list_extend(cmd, { "-e", pattern, "--", "." })
    process = vim.system(cmd, { cwd = ctx.cwd }, function(result)
      vim.schedule(function()
        if ctx.is_cancelled() then
          return
        end
        if result.code ~= 0 and result.code ~= 1 then
          ctx.fail(result.stderr ~= "" and result.stderr or ("rg exited with " .. result.code))
          return
        end
        local iterator = (result.stdout or ""):gmatch("[^\n]+")
        local items = {}
        local function decode()
          if ctx.is_cancelled() then
            return
          end
          for _ = 1, 500 do
            local line = iterator()
            if not line or #items >= (opts.limit or 10000) then
              ctx.set_items(items)
              ctx.done()
              return
            end
            local ok, event = pcall(vim.json.decode, line)
            if ok and event.type == "match" then
              local data = event.data
              local function value(field)
                return field.text or vim.base64.decode(field.bytes)
              end
              local sub = data.submatches[1]
              local item = M.location(
                value(data.path):gsub("^%./", ""),
                data.line_number,
                sub and sub.start or 0,
                value(data.lines),
                ctx.cwd
              )
              item.match_text = sub and value(sub.match) or ""
              if transform then
                item = transform(item, data)
              end
              if item then
                items[#items + 1] = item
              end
            elseif not ok then
              ctx.fail("invalid rg JSON output")
              return
            end
          end
          vim.schedule(decode)
        end
        decode()
      end)
    end)
  end
  if (opts.debounce_ms or 30) > 0 then
    timer = vim.defer_fn(start, opts.debounce_ms or 30)
  else
    start()
  end
  return function()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if process and not process:is_closing() then
      pcall(process.kill, process, 15)
    end
  end
end

return M
