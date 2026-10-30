local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("selection_tools_details")

function M.close(picker, focus)
  local win, buf = picker.detail_win, picker.detail_buf
  picker.detail_win, picker.detail_buf = nil, nil
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_close(win, true)
  end
  if buf and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_delete(buf, { force = true })
  end
  if focus and not picker.closed and api.nvim_win_is_valid(picker.input_win) then
    api.nvim_set_current_win(picker.input_win)
    vim.cmd.startinsert({ bang = true })
  end
end

function M.open(picker)
  if picker.closed then
    return
  end
  if picker.detail_win then
    M.close(picker, true)
    return
  end
  local entry = picker.matches[picker.index]
  if not entry then
    return
  end
  local item = entry.item
  local lines, body, content = {}, 0
  local function add(text)
    lines[#lines + 1] = tostring(text):gsub("[\r\n]", " ")
  end
  if type(item) == "table" then
    local path = item.file or ((item.bufnr or item.buf) and api.nvim_buf_get_name(item.bufnr or item.buf))
    if path then
      add("File: " .. path)
    end
    if item.pos then
      add(("Position: %d:%d"):format(item.pos[1], (item.pos[2] or 0) + 1))
    end
    if item.commit then
      add("Commit: " .. item.commit)
    end
    content = item.code or item.detail or (item.lines and table.concat(item.lines, "\n")) or item.text
  end
  content = tostring(content or entry.raw_text or entry.text)
  if #lines > 0 then
    add("")
  end
  body = #lines
  vim.list_extend(lines, vim.split(content:gsub("\r\n", "\n"), "\n", { plain = true }))
  local width, height =
    math.max(4, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.9))),
    math.max(1, math.min(vim.o.lines - 4, math.max(4, #lines)))
  local buf = api.nvim_create_buf(false, true)
  picker.detail_buf = buf
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "wipe", false
  vim.b[buf].completion = false
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Item details · q/Esc back · C-y copy ",
    zindex = 75,
  })
  picker.detail_win = win
  vim.cmd.stopinsert()
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:SelectionToolsBorder"
  if body > 0 then
    api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_row = body, end_col = 0, hl_group = "Comment" })
  end
  if type(item) == "table" and item.code then
    for _, span in ipairs(item.line_matches or {}) do
      if span[1] < span[2] and span[2] <= #item.code then
        api.nvim_buf_set_extmark(buf, ns, body, span[1], { end_col = span[2], hl_group = "SelectionToolsMatch" })
      end
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "<F2>" }) do
    vim.keymap.set("n", key, function()
      M.close(picker, true)
    end, { buffer = buf, silent = true, nowait = true })
  end
  vim.keymap.set("n", "<C-y>", function()
    vim.fn.setreg("+", content)
  end, { buffer = buf, silent = true })
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        if picker.detail_win == win then
          M.close(picker, true)
        end
      end)
    end,
  })
end
return M
