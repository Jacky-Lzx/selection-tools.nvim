local util = require("selection_tools.sources.util")

return function(opts)
  opts = opts or {}
  assert(
    opts.compare == nil or opts.compare == "parent" or opts.compare == "current",
    "undo.compare must be parent or current"
  )
  local origin = util.capture()
  local tree = vim.fn.undotree()
  local name = vim.api.nvim_buf_get_name(origin.buf)
  local filename = name ~= "" and vim.fs.basename(name) or "[No Name]"
  local cwd = opts.cwd or (name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd())
  local delta = vim.tbl_extend("force", { args = { "--file-style=omit" } }, opts.delta or {})
  local history = require("selection_tools.sources.undo_tree").new(tree)
  local current = vim.api.nvim_buf_get_lines(origin.buf, 0, -1, false)
  local current_text = table.concat(current, "\n") .. (vim.bo[origin.buf].endofline and "\n" or "")
  local clone, undo_file
  local function cleanup()
    if clone and vim.api.nvim_buf_is_valid(clone) then
      vim.api.nvim_buf_delete(clone, { force = true })
    end
    if undo_file then
      vim.fn.delete(undo_file)
    end
    clone, undo_file = nil, nil
  end
  local function snapshot(seq)
    if seq == tree.seq_cur then
      return current, current_text
    end
    if not clone then
      undo_file = vim.fn.tempname()
      vim.api.nvim_buf_call(origin.buf, function()
        vim.cmd("silent wundo! " .. vim.fn.fnameescape(undo_file))
      end)
      clone = vim.api.nvim_create_buf(false, true)
      vim.bo[clone].bufhidden = "hide"
      vim.api.nvim_buf_set_lines(clone, 0, -1, false, current)
      vim.bo[clone].endofline = vim.bo[origin.buf].endofline
      vim.api.nvim_buf_call(clone, function()
        vim.cmd("silent rundo " .. vim.fn.fnameescape(undo_file))
      end)
    end
    vim.api.nvim_buf_call(clone, function()
      vim.cmd("silent undo " .. seq)
    end)
    local lines = vim.api.nvim_buf_get_lines(clone, 0, -1, false)
    return lines, table.concat(lines, "\n") .. (vim.bo[clone].endofline and "\n" or "")
  end
  local function wrap_value(picker)
    if picker.git_tools_diff_wrap ~= nil then
      return picker.git_tools_diff_wrap
    end
    local available, window = pcall(require, "git_tools.diff.window")
    return available and window.options({ wrap = opts.wrap }).wrap or opts.wrap == true
  end
  local function show(ctx, lines, ft, title)
    ctx.set_lines(lines, ft, title)
    -- set_lines publishes asynchronously and may switch the displayed buffer,
    -- which restores that buffer's saved window options.
    vim.schedule(function()
      if not ctx.is_cancelled() and vim.api.nvim_win_is_valid(ctx.win) then
        vim.wo[ctx.win].wrap = wrap_value(ctx.picker)
      end
    end)
  end
  return {
    prompt = "Undo · " .. filename .. " · F4 compare",
    compare = opts.compare or "parent",
    items = history(opts.query or ""),
    live = true,
    match = false,
    result_layout = "undo",
    finder = function(ctx)
      ctx.set_items(history(ctx.query))
      ctx.done()
    end,
    resume_refresh = true,
    format_item = util.format,
    highlight_item = function(item)
      return item.highlights
    end,
    preview = { enabled = true, title = true },
    actions = {
      undo_wrap = function(picker)
        local provider = picker.preview and picker.preview.provider
        if type(provider) == "table" and type(provider.toggle_wrap) == "function" then
          provider:toggle_wrap()
        else
          picker.git_tools_diff_wrap = not wrap_value(picker)
          if picker.preview_win and vim.api.nvim_win_is_valid(picker.preview_win) then
            vim.wo[picker.preview_win].wrap = picker.git_tools_diff_wrap
          end
        end
      end,
      undo_compare = function(picker)
        picker.opts.compare = picker.opts.compare == "parent" and "current" or "parent"
        if picker.opts.source_opts then
          picker.opts.source_opts.compare = picker.opts.compare
        end
        if picker.preview then
          picker.preview.initialized = false
        end
        picker:_render()
      end,
    },
    keys = { undo_compare = { "<F4>" }, undo_wrap = { "<M-z>" } },
    on_close = cleanup,
    previewer = function(ctx)
      vim.wo[ctx.win].number = false
      if not vim.api.nvim_buf_is_valid(origin.buf) or vim.api.nvim_buf_get_changedtick(origin.buf) ~= origin.tick then
        show(ctx, { "Original buffer changed; reopen undo history" })
        return
      end
      local compare = ctx.picker.opts.compare
      local from = compare == "current" and tree.seq_cur or ctx.item.parent
      local title = ("%s #%d → #%d"):format(
        compare == "parent" and "Step" or "Current",
        from or ctx.item.seq,
        ctx.item.seq
      )
      if compare == "current" and ctx.item.current then
        show(ctx, { "Current version (no changes)" }, "text", title)
        return
      end
      local target, target_text = snapshot(ctx.item.seq)
      if compare == "parent" and ctx.item.parent == nil then
        local reason = ctx.item.seq == 0 and "Initial state (no parent change)"
          or "Parent snapshot is no longer in undo history"
        show(ctx, #target == 1 and target[1] == "" and { reason } or target, vim.bo[origin.buf].filetype, reason)
        return
      end
      local available, diff = pcall(require, "git_tools.diff")
      if not available then
        show(ctx, target, vim.bo[origin.buf].filetype, "Undo snapshot · install git-tools.nvim for diff")
        return
      end
      local before = current_text
      if compare == "parent" then
        local _, text = snapshot(ctx.item.parent)
        before = text
      end
      local patch, source = diff.unified(before, target_text, {
        old_path = (compare == "parent" and ("undo-" .. from) or "current") .. "/" .. filename,
        new_path = "undo-" .. ctx.item.seq .. "/" .. filename,
        ft = vim.bo[origin.buf].filetype,
      })
      if #patch == 0 then
        show(
          ctx,
          { compare == "parent" and "No text changes in this step" or "Current version (no changes)" },
          "text",
          title
        )
        return
      end
      local view = vim.tbl_extend("force", {}, ctx, {
        set_buffer = function(buf, metadata)
          return ctx.set_buffer(
            buf,
            vim.tbl_extend(
              "force",
              {},
              metadata or {},
              { title = title .. " · " .. (metadata.backend == "delta" and "delta" or "diff") }
            )
          )
        end,
      })
      return diff.render(view, patch, {
        backend = opts.backend or "native",
        wrap = opts.wrap,
        sources = { source },
        native = vim.tbl_extend("force", { file_header = false }, opts.native or {}),
        delta = delta,
        cwd = cwd,
        title = title,
      }, function()
        return vim.api.nvim_buf_is_valid(origin.buf) and vim.api.nvim_buf_get_changedtick(origin.buf) == origin.tick
      end)
    end,
    on_choice = function(item)
      if item and not item.current then
        util.context(origin, function()
          vim.cmd("silent undo " .. item.seq)
        end, true)
      end
    end,
  }
end
