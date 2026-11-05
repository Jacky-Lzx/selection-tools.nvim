local api = vim.api
local M = {}

-- Hit-test screen cells ourselves: non-focusable preview/border floats let
-- native mouse events pass through to the editor underneath them.
local function row_at(win, mouse, border)
  if not win or not api.nvim_win_is_valid(win) then
    return
  end
  local pos = api.nvim_win_get_position(win)
  local row, col = mouse.screenrow - pos[1], mouse.screencol - pos[2]
  local height, width = api.nvim_win_get_height(win), api.nvim_win_get_width(win)
  if border then
    local chars = api.nvim_win_get_config(win).border or {}
    local function size(index)
      local value = chars[index]
      value = type(value) == "table" and value[1] or value
      return value and value ~= "" and 1 or 0
    end
    height, width = height + size(2) + size(6), width + size(4) + size(8)
  end
  if row >= 1 and row <= height and col >= 1 and col <= width then
    return row
  end
end

function M.setup(picker)
  local function handle(key, action)
    if picker.closed then
      return key
    end
    local mouse = vim.fn.getmousepos()
    local row = row_at(picker.list_win, mouse)
    local input = row_at(picker.input_win, mouse)
    local preview = row_at(picker.preview_win, mouse) or row_at(picker.preview and picker.preview.scroll.win, mouse)
    if action == "up" or action == "down" then
      local direction = action == "up" and -1 or 1
      if preview then
        picker:scroll_preview(direction, 3)
      elseif row or input then
        if not picker.matching and not picker.finder_pending and not picker.syntax_pending then
          local delta = direction * (picker.opts.layout.reverse and -3 or 3)
          if #picker.matches > 0 then
            local index = math.max(1, math.min(#picker.matches, picker.index + delta))
            if index ~= picker.index then
              picker.index = index
              picker:_render()
            end
          end
        end
      else
        return row_at(picker.frame_win, mouse, true) and "" or key
      end
      return ""
    end
    if row then
      local index = picker.row_to_index[row]
      if index and not picker.matching and not picker.finder_pending and not picker.syntax_pending then
        if action ~= "release" then
          if picker.index ~= index then
            picker.index = index
            picker:_render()
          end
          if action == "confirm" then
            picker:confirm()
          elseif action == "toggle" then
            picker:toggle()
          end
        end
      end
      return ""
    end
    if input then
      if action == "select" and api.nvim_get_current_win() ~= picker.input_win then
        vim.schedule(function()
          if not picker.closed and api.nvim_get_current_win() == picker.input_win then
            vim.cmd.startinsert()
          end
        end)
      end
      return key
    end
    if preview or row_at(picker.frame_win, mouse, true) then
      return ""
    end
    return key -- Preserve native outside-click focus and cancellation.
  end
  local keys = {
    ["<LeftMouse>"] = "select",
    ["<2-LeftMouse>"] = "confirm",
    ["<3-LeftMouse>"] = "select",
    ["<4-LeftMouse>"] = "select",
    ["<C-LeftMouse>"] = "toggle",
    ["<C-2-LeftMouse>"] = "toggle",
    ["<C-3-LeftMouse>"] = "toggle",
    ["<C-4-LeftMouse>"] = "toggle",
    ["<C-LeftRelease>"] = "release",
    ["<C-LeftDrag>"] = "select",
    ["<LeftDrag>"] = "select",
    ["<LeftRelease>"] = "release",
    ["<ScrollWheelUp>"] = "up",
    ["<ScrollWheelDown>"] = "down",
  }
  -- Clicks and scrolling retain the search focus, including when a provider
  -- displays a caller-owned or terminal buffer in the preview pane.
  for _, buf in ipairs({ picker.input_buf, picker.list_buf, picker.preview_buf }) do
    for key, action in pairs(keys) do
      vim.keymap.set({ "i", "n" }, key, function()
        local fallback = handle(key, action)
        if fallback ~= "" then
          api.nvim_feedkeys(api.nvim_replace_termcodes(fallback, true, false, true), "in", false)
        end
      end, { buffer = buf, silent = true, nowait = true })
    end
  end
end

return M
