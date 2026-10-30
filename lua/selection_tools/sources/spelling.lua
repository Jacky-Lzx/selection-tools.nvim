local util = require("selection_tools.sources.util")
return function(opts)
  local origin = util.capture()
  local row, col = unpack(origin.cursor)
  local line = vim.api.nvim_buf_get_lines(origin.buf, row - 1, row, false)[1] or ""
  local word, start, finish = "", -1, -1
  local offset = 0
  while offset <= #line do
    local match = vim.fn.matchstrpos(line, [[\k\+]], offset)
    if match[2] < 0 then
      break
    end
    if match[3] > col then
      word, start, finish = unpack(match)
      break
    end
    offset = match[3]
  end
  local items = {}
  for _, suggestion in ipairs(word ~= "" and (opts.suggestions or vim.fn.spellsuggest(word, opts.limit or 25)) or {}) do
    items[#items + 1] = { text = suggestion, word = suggestion, detail = word .. " → " .. suggestion }
  end
  return {
    prompt = "Spelling: " .. word,
    items = items,
    resume_refresh = true,
    format_item = util.format,
    layout = { width = 0.5, min_width = 40, max_width = 100, height = 0.4, input_position = "top", reverse = false },
    preview = { enabled = false },
    previewer = util.preview,
    on_choice = function(item)
      if item and start >= 0 then
        util.context(origin, function()
          vim.api.nvim_buf_set_text(origin.buf, row - 1, start, row - 1, finish, { item.word })
          vim.api.nvim_win_set_cursor(0, { row, start })
        end, true)
      end
    end,
  }
end
