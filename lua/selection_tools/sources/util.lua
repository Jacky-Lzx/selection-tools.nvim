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

function M.definition(callback, sid, lnum, script_name)
  if type(callback) == "function" then
    local info = debug.getinfo(callback, "S")
    if info and info.source:sub(1, 1) == "@" then
      return { file = info.source:sub(2), pos = { math.max(1, info.linedefined), 0 } }
    end
  end
  if sid and sid > 0 then
    if script_name then
      local file = script_name(sid)
      if file then
        return { file = file, pos = { math.max(1, lnum or 1), 0 } }
      end
    else
      for _, script in ipairs(vim.fn.getscriptinfo()) do
        if script.sid == sid and script.name ~= "" then
          return { file = script.name, pos = { math.max(1, lnum or 1), 0 } }
        end
      end
    end
  end
end

-- Keep the script index local to one picker; later pickers see newly loaded scripts.
function M.definitions()
  local scripts
  local function script_name(sid)
    if not scripts then
      scripts = {}
      for _, script in ipairs(vim.fn.getscriptinfo()) do
        if script.name ~= "" then
          scripts[script.sid] = script.name
        end
      end
    end
    return scripts[sid]
  end
  return function(callback, sid, lnum)
    return M.definition(callback, sid, lnum, script_name)
  end
end

function M.show(item)
  vim.cmd("botright new")
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].buflisted = false
  api.nvim_buf_set_lines(buf, 0, -1, false, item.lines or vim.split(item.detail or item.text, "\n", { plain = true }))
  vim.bo[buf].filetype = item.ft or "text"
  vim.bo[buf].modified, vim.bo[buf].modifiable = false, false
end

-- Defer the first batch until the UI can redraw, then yield between batches.
-- produce(checkpoint) returns candidates; done optionally consumes them internally.
function M.collect(ctx, produce, done)
  local cancelled, timer, deadline, units = false, nil, 0, 0
  local function current()
    return not cancelled and not ctx.is_cancelled()
  end
  local thread = coroutine.create(function()
    return produce(function()
      units = units + 1
      if units >= 2048 or vim.uv.hrtime() >= deadline then
        coroutine.yield()
      end
    end)
  end)
  local step
  step = function()
    timer = nil
    if not current() then
      return
    end
    deadline, units = vim.uv.hrtime() + 2000000, 0
    local ok, result = coroutine.resume(thread)
    if not current() then
      return
    end
    if not ok then
      ctx.fail(result)
    elseif coroutine.status(thread) == "dead" then
      if done then
        done(result)
      else
        ctx.set_items(result)
        ctx.done()
      end
    else
      timer = vim.defer_fn(step, 1)
    end
  end
  timer = vim.defer_fn(step, 1)
  return function()
    cancelled = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
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
    local ok, spawned = pcall(vim.system, cmd, { cwd = ctx.cwd }, function(result)
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
    if ok then
      process = spawned
    else
      ctx.fail(tostring(spawned))
    end
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
