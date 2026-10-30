local util = require("selection_tools.sources.util")

return function()
  local origin = util.capture()
  local tree = vim.fn.undotree()
  local items, seen = {}, {}
  local function collect(entries)
    for _, entry in ipairs(entries or {}) do
      if not seen[entry.seq] then
        seen[entry.seq] = true
        items[#items + 1] = {
          key = entry.seq,
          seq = entry.seq,
          text = ("seq %d%s  %s"):format(
            entry.seq,
            entry.seq == tree.seq_cur and " [current]" or "",
            os.date("%Y-%m-%d %H:%M:%S", entry.time)
          ),
        }
      end
      collect(entry.alt)
    end
  end
  collect(tree.entries)
  if seen[1] then
    items[#items + 1] = { key = 0, seq = 0, text = "seq 0  initial state" }
  end
  table.sort(items, function(a, b)
    return a.seq > b.seq
  end)
  local current = vim.api.nvim_buf_get_lines(origin.buf, 0, -1, false)
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
  return {
    prompt = "Undo history",
    items = items,
    resume_refresh = true,
    format_item = util.format,
    preview = { enabled = true },
    on_close = cleanup,
    previewer = function(ctx)
      if vim.api.nvim_buf_get_changedtick(origin.buf) ~= origin.tick then
        ctx.set_lines({ "Original buffer changed; reopen undo history" })
        return
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
        vim.cmd("silent undo " .. ctx.item.seq)
      end)
      local target = vim.api.nvim_buf_get_lines(clone, 0, -1, false)
      local diff = vim.diff(
        table.concat(current, "\n") .. "\n",
        table.concat(target, "\n") .. "\n",
        { result_type = "unified", ctxlen = 3 }
      )
      ctx.set_lines(
        diff == "" and { "Current version (no changes)" }
          or vim.split("--- current\n+++ seq " .. ctx.item.seq .. "\n" .. diff, "\n", { plain = true }),
        "diff",
        "Undo preview"
      )
    end,
    on_choice = function(item)
      if item then
        util.context(origin, function()
          vim.cmd("silent undo " .. item.seq)
        end, true)
      end
    end,
  }
end
