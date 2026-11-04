local api = vim.api
local ns = api.nvim_create_namespace("selection_tools_preview_scroll")
local Scroll = {}
Scroll.__index = Scroll

function Scroll.new(picker)
  local self = setmetatable({ picker = picker }, Scroll)
  -- Non-focused floats do not reliably emit WinScrolled. Observe their actual
  -- redraw instead, then defer all UI mutations until outside the redraw lock.
  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, buf, top, bottom)
      if picker.closed or win ~= picker.preview_win then
        return false
      end
      local key = ("%d:%d:%d:%d:%d:%d"):format(
        win,
        buf,
        top,
        bottom,
        api.nvim_buf_line_count(buf),
        api.nvim_win_get_height(win)
      )
      if key ~= self.view_key then
        self.view_key = key
        if not self.pending then
          self.pending = true
          vim.schedule(function()
            self.pending = false
            if not picker.closed then
              picker:_draw_separators()
            end
          end)
        end
      end
      return false
    end,
  })
  return self
end

function Scroll:hide()
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

function Scroll:close()
  api.nvim_set_decoration_provider(ns, {})
  self:hide()
  if self.buf and api.nvim_buf_is_valid(self.buf) then
    api.nvim_buf_delete(self.buf, { force = true })
  end
  self.buf = nil
end

-- Read the displayed window, which may contain a borrowed or terminal buffer.
-- This state belongs to the ready frame, including while its replacement loads.
function Scroll:update()
  local p, label = self.picker, nil
  local win, preview, opts = p.preview_win, p.preview, p.opts.preview
  if p.closed or not win or not api.nvim_win_is_valid(win) or not preview.displayed or preview.scrollable == false then
    self:hide()
    return
  end
  local total = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  local height = api.nvim_win_get_height(win)
  local top, bottom = unpack(api.nvim_win_call(win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end))
  top, bottom = math.max(1, top), math.min(total, math.max(top, bottom))
  local overflow = top > 1 or bottom < total
  local progress = overflow and math.min(1, (top - 1) / math.max(1, total - height)) or 1
  if opts.position and (overflow or preview.truncated) then
    local arrows = (top > 1 and "↑" or "") .. (bottom < total and "↓" or "")
    label = (arrows ~= "" and (arrows .. " ") or "") .. ("%d%%"):format(math.floor(progress * 100))
    if preview.truncated then
      label = label .. " · truncated"
    end
  end
  if not opts.scrollbar or not overflow then
    self:hide()
    return label
  end
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then
    self.buf = api.nvim_create_buf(false, true)
    vim.bo[self.buf].bufhidden = "hide"
    vim.b[self.buf].completion = false
    vim.bo[self.buf].filetype = "selection_tools_scrollbar"
  end
  local size = math.max(1, math.floor(height * math.min(height, total) / total))
  local offset = math.floor((height - size) * progress)
  local lines = {}
  for row = 1, height do
    lines[row] = row > offset and row <= offset + size and "┃" or "│"
  end
  vim.bo[self.buf].modifiable = true
  api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  api.nvim_buf_set_extmark(self.buf, ns, offset, 0, {
    end_row = offset + size,
    hl_group = "SelectionToolsPreviewThumb",
  })
  local pos = api.nvim_win_get_position(win)
  local config = {
    relative = "editor",
    row = pos[1],
    col = pos[2] + api.nvim_win_get_width(win),
    width = 1,
    height = height,
    style = "minimal",
    border = "none",
    focusable = false,
    zindex = 63,
  }
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, config)
  else
    self.win = api.nvim_open_win(self.buf, false, config)
    vim.wo[self.win].wrap = false
    vim.wo[self.win].winhighlight = "Normal:SelectionToolsPreviewTrack"
  end
  return label
end

return Scroll
