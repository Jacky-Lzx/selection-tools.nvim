-- Bounded, cancellable newline-delimited process output. Parsing is scheduled in
-- batches so UI input and cancellation can run while the producer is still alive.
local M = {}
function M.start(cmd, opts, ctx, decode)
  local process, cancelled, ended, scheduled, exited, result
  local queue, read, pending, bytes, count = {}, 1, "", 0, 0
  local reason, stream_error
  local limit, max_output = opts.limit or 10000, opts.max_output or 32 * 1024 * 1024
  local max_line = opts.max_line_bytes or 1024 * 1024
  assert(limit >= 1 and max_output >= 1 and max_line >= 1, "Search limits must be positive")
  local function kill()
    if process and not process:is_closing() then
      pcall(process.kill, process, 15)
    end
  end
  local function finish(err)
    if ended or cancelled or ctx.is_cancelled() then
      return
    end
    ended = true
    queue, pending = {}, ""
    if err then
      kill()
      ctx.fail(err)
    else
      ctx.done({ truncated = reason })
    end
  end
  local pump
  local function schedule()
    if not scheduled and not ended and not cancelled then
      scheduled = true
      vim.schedule(function()
        scheduled = false
        pump()
      end)
    end
  end
  pump = function()
    if ended or cancelled or ctx.is_cancelled() then
      return
    end
    if stream_error then
      finish(stream_error)
      return
    end
    local items = {}
    for _ = 1, 500 do
      local newline = pending:find("\n", 1, true)
      while not newline and queue[read] do
        pending = pending .. queue[read]
        queue[read], read = false, read + 1
        newline = pending:find("\n", 1, true)
        if #pending > max_line and not newline then
          break
        end
      end
      if (newline and newline - 1 > max_line) or (not newline and #pending > max_line) then
        reason = "line size limit"
        kill()
        if #items > 0 then
          ctx.append_items(items)
        end
        finish()
        return
      end
      if not newline then
        if exited and #pending > 0 and not reason then
          newline = #pending + 1
        else
          break
        end
      end
      local line = pending:sub(1, newline - 1)
      pending = pending:sub(newline + 1)
      if line ~= "" then
        local ok, item = pcall(decode, line)
        if not ok then
          finish(item)
          return
        end
        if item then
          count = count + 1
          items[#items + 1] = item
          if count >= limit then
            reason = "result limit"
            ctx.append_items(items)
            kill()
            finish()
            return
          end
        end
      end
    end
    if #items > 0 then
      ctx.append_items(items)
    end
    if queue[read] or pending:find("\n", 1, true) then
      schedule()
    elseif exited then
      if reason then
        finish()
      elseif result.code ~= 0 and result.code ~= 1 then
        finish(result.stderr ~= "" and result.stderr or ("Search exited with code " .. result.code))
      elseif pending ~= "" then
        schedule()
      else
        finish()
      end
    else
      -- Release consumed chunk references and indexes between producer bursts.
      queue, read = {}, 1
    end
  end
  local ok, spawned = pcall(vim.system, cmd, {
    cwd = ctx.cwd,
    stdout = function(err, data)
      if ended or cancelled or ctx.is_cancelled() then
        return
      end
      if err then
        stream_error = tostring(err)
      end
      if data and not reason then
        local available = math.max(0, max_output - bytes)
        bytes = bytes + #data
        if #data > available then
          reason = "output size limit"
          kill()
        end
        if available > 0 then
          queue[#queue + 1] = data:sub(1, available)
        end
      end
      schedule()
    end,
  }, function(value)
    result, exited = value, true
    schedule()
  end)
  if ok then
    process = spawned
  else
    stream_error = tostring(spawned)
    schedule()
  end
  return function()
    cancelled = true
    queue, pending = {}, ""
    kill()
  end
end
return M
