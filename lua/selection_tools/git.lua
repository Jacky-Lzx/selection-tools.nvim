local M = {}
local api = vim.api
function M.command(root, args)
  local cmd = { "git", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "-C", root }
  vim.list_extend(cmd, args)
  return cmd
end
function M.root(ctx, callback)
  local cancel
  local process = vim.system(
    M.command(ctx.cwd, { "rev-parse", "--show-toplevel" }),
    {},
    vim.schedule_wrap(function(result)
      if ctx.is_cancelled() then
        return
      end
      if result.code ~= 0 then
        ctx.fail("Not a Git worktree: " .. (result.stderr or ""))
        return
      end
      local root = result.stdout:gsub("\n$", "")
      cancel = callback(root)
    end)
  )
  return function()
    if cancel then
      cancel()
    end
    if not process:is_closing() then
      pcall(process.kill, process, 15)
    end
  end
end

local function lines(root, args, ctx, callback)
  local output = {}
  return require("selection_tools.stream").start(M.command(root, args), {
    limit = ctx.max_lines or 10000,
    max_output = ctx.max_size or 1024 * 1024,
    max_line_bytes = 256 * 1024,
    keep_empty = true,
  }, {
    cwd = root,
    is_cancelled = ctx.is_cancelled,
    append_items = function(batch)
      vim.list_extend(output, batch)
    end,
    done = function(status)
      if status.truncated then
        output[#output + 1] = "… diff truncated: " .. status.truncated
      end
      callback(output, status)
    end,
    fail = function(err)
      callback({ "Git error: " .. tostring(err) })
    end,
  }, function(line)
    return line
  end)
end

function M.diff(item, ctx)
  local root = item.root
  if item.commit then
    return lines(root, {
      "show",
      "--format=fuller",
      "--stat",
      "--patch",
      "--no-ext-diff",
      "--no-textconv",
      "--no-color",
      item.commit,
      "--",
    }, ctx, ctx.set_lines)
  end
  local work = {}
  local function args(cached)
    local cmd = { "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3" }
    if cached then
      cmd[#cmd + 1] = "--cached"
    end
    cmd[#cmd + 1] = "--"
    if item.old_file then
      cmd[#cmd + 1] = item.old_file
    end
    cmd[#cmd + 1] = item.relative_file
    return cmd
  end
  if item.untracked then
    return lines(
      root,
      { "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", item.file },
      ctx,
      ctx.set_lines
    )
  end
  if item.index_change then
    work[#work + 1] = { "Staged", args(true) }
  end
  if item.worktree_change then
    work[#work + 1] = { "Working tree", args(false) }
  end
  local output, cancel, index = {}, nil, 0
  local function next_diff()
    if ctx.is_cancelled() then
      return
    end
    index = index + 1
    if not work[index] then
      ctx.set_lines(#output > 0 and output or { "No textual diff (metadata or binary change)" })
      return
    end
    local size = 0
    for _, line in ipairs(output) do
      size = size + #line + 1
    end
    local remaining_lines = (ctx.max_lines or 10000) - #output - 1
    local remaining_size = (ctx.max_size or 1024 * 1024) - size - 32
    if remaining_lines < 1 or remaining_size < 1 then
      output[#output + 1] = "… diff truncated: combined section limit"
      ctx.set_lines(output)
      return
    end
    output[#output + 1] = "# " .. work[index][1]
    local budget = vim.tbl_extend("force", {}, ctx, { max_lines = remaining_lines, max_size = remaining_size })
    cancel = lines(root, work[index][2], budget, function(data, status)
      vim.list_extend(output, data)
      if status and status.truncated then
        ctx.set_lines(output)
      else
        next_diff()
      end
    end)
  end
  next_diff()
  return function()
    if cancel then
      cancel()
    end
  end
end

function M.previewer(opts)
  return function(ctx)
    return M.diff(ctx.item, {
      is_cancelled = ctx.is_cancelled,
      max_lines = opts.max_lines,
      max_size = opts.max_size,
      set_lines = function(data)
        ctx.set_lines(data, "diff", ctx.item.commit or ctx.item.relative_file)
      end,
    })
  end
end

function M.open_diff(item)
  if not item then
    return
  end
  vim.cmd("botright new")
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "wipe", false
  vim.bo[buf].filetype = "diff"
  api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading diff…" })
  vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
  local cancel = M.diff(item, {
    is_cancelled = function()
      return not api.nvim_buf_is_valid(buf)
    end,
    set_lines = function(data)
      if not api.nvim_buf_is_valid(buf) then
        return
      end
      vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
      api.nvim_buf_set_lines(buf, 0, -1, false, #data > 0 and data or { "No textual diff" })
      vim.bo[buf].modified, vim.bo[buf].modifiable, vim.bo[buf].readonly = false, false, true
      require("selection_tools.diff").decorate(buf, data)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = cancel })
end
return M
