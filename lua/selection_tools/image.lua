local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("selection_tools_image")
local palette = {
  "#000000",
  "#cd0000",
  "#00cd00",
  "#cdcd00",
  "#0000ee",
  "#cd00cd",
  "#00cdcd",
  "#e5e5e5",
  "#7f7f7f",
  "#ff0000",
  "#00ff00",
  "#ffff00",
  "#5c5cff",
  "#ff00ff",
  "#00ffff",
  "#ffffff",
}

-- chafa is forced to 16 colors and unoptimized SGR-only symbol output. Decode
-- those colors into buffer highlights; never send process escape codes to a TTY.
function M.decode(output)
  local lines, spans, fg, bg = {}, {}, nil, nil
  for row, raw in ipairs(vim.split(output:gsub("\r", ""), "\n", { plain = true })) do
    local text, at = "", 1
    local function append(part)
      part = part:gsub("[%z\1-\8\11-\31\127]", "")
      if #part > 0 and (fg or bg) then
        spans[#spans + 1] = { row - 1, #text, #text + #part, fg = fg, bg = bg }
      end
      text = text .. part
    end
    while true do
      local first, last, code = raw:find("\27%[([%d;]*)m", at)
      if not first then
        append(raw:sub(at))
        break
      end
      append(raw:sub(at, first - 1))
      local values = vim.split(code == "" and "0" or code, ";", { plain = true })
      local i = 1
      while i <= #values do
        local value = tonumber(values[i]) or 0
        if value == 0 then
          fg, bg = nil, nil
        elseif value == 39 then
          fg = nil
        elseif value == 49 then
          bg = nil
        elseif value >= 30 and value <= 37 then
          fg = value - 30
        elseif value >= 40 and value <= 47 then
          bg = value - 40
        elseif value >= 90 and value <= 97 then
          fg = value - 90 + 8
        elseif value >= 100 and value <= 107 then
          bg = value - 100 + 8
        elseif (value == 38 or value == 48) and values[i + 1] == "5" then
          local color = tonumber(values[i + 2])
          color = color and color >= 0 and color < 16 and color or nil
          if value == 38 then
            fg = color
          else
            bg = color
          end
          i = i + 2
        end
        i = i + 1
      end
      at = last + 1
    end
    lines[row] = text
  end
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines, spans
end
function M.paint(buf, spans)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, span in ipairs(spans) do
    local name = "SelectionToolsImage_" .. (span.fg or "none") .. "_" .. (span.bg or "none")
    local function color(index)
      return index and (vim.g["terminal_color_" .. index] or palette[index + 1]) or nil
    end
    api.nvim_set_hl(0, name, { fg = color(span.fg), bg = color(span.bg) })
    api.nvim_buf_set_extmark(buf, ns, span[1], span[2], { end_col = span[3], hl_group = name })
  end
end

function M.render(path, opts, ctx)
  local cancelled, process, placement, temporary
  local number = api.nvim_win_is_valid(ctx.win) and vim.wo[ctx.win].number
  local function current()
    return not cancelled and not ctx.is_cancelled()
  end
  local function fail(message)
    if current() then
      ctx.write({ "Image preview: " .. message })
    end
  end
  local function run(cmd, callback)
    local ok, result = pcall(
      vim.system,
      cmd,
      { timeout = opts.timeout_ms or 5000 },
      vim.schedule_wrap(function(result)
        if not current() then
          return
        end
        if result.code ~= 0 then
          fail((result.stderr or "converter failed"):gsub("[\r\n]", " "))
          return
        end
        callback(result.stdout or "")
      end)
    )
    if ok then
      process = result
    else
      fail(tostring(result))
    end
  end
  local function symbols(file)
    if vim.fn.executable("chafa") ~= 1 then
      fail("requires chafa or Snacks.image with a supported terminal")
      return
    end
    local width = math.max(1, api.nvim_win_get_width(ctx.win))
    local height = math.max(1, api.nvim_win_get_height(ctx.win))
    run({
      "chafa",
      "--format=symbols",
      "--colors=16",
      "--symbols=vhalf",
      "--optimize=0",
      "--animate=off",
      "--probe=off",
      "--relative=off",
      "--polite=on",
      "--threads=1",
      "--size=" .. width .. "x" .. height,
      "--",
      file,
    }, function(output)
      local lines, spans = M.decode(output)
      ctx.write(lines, function()
        vim.wo[ctx.win].number = false
        M.paint(ctx.buf, spans)
      end)
    end)
  end
  vim.uv.fs_stat(
    path,
    vim.schedule_wrap(function(err, stat)
      if not current() then
        return
      end
      if not stat or stat.type ~= "file" then
        fail(tostring(err or "requires a regular file"))
        return
      end
      if stat.size > (opts.max_size or 20 * 1024 * 1024) then
        fail("file exceeds image size limit")
        return
      end
      local backend = opts.backend or "auto"
      if backend ~= "chafa" and _G.Snacks and #api.nvim_list_uis() > 0 then
        local ok, image = pcall(function()
          return Snacks.image
        end)
        local supported = ok and pcall(function()
          assert(image.supports(path))
        end)
        if supported then
          ctx.write({ "" }, function()
            vim.wo[ctx.win].number = false
            local placed, value = pcall(image.placement.new, ctx.buf, path, { inline = false, auto_resize = true })
            if placed then
              placement = value
            else
              fail(tostring(value))
            end
          end)
          return
        end
      end
      if backend == "snacks" then
        fail("Snacks.image or terminal image support unavailable")
        return
      end
      local ext = path:match("%.([^%.]+)$"):lower()
      if ext == "pdf" then
        if vim.fn.executable("pdftoppm") ~= 1 then
          fail("PDF conversion requires pdftoppm")
          return
        end
        temporary = vim.fn.tempname()
        vim.fn.mkdir(temporary, "p")
        local prefix = temporary .. "/page"
        run({ "pdftoppm", "-f", "1", "-l", "1", "-singlefile", "-png", "-scale-to", "1600", path, prefix }, function()
          symbols(prefix .. ".png")
        end)
      elseif ext == "svg" and vim.fn.executable("rsvg-convert") == 1 then
        temporary = vim.fn.tempname()
        vim.fn.mkdir(temporary, "p")
        local file = temporary .. "/image.png"
        run(
          { "rsvg-convert", "--keep-aspect-ratio", "--width", "1600", "--height", "1600", "--output", file, path },
          function()
            symbols(file)
          end
        )
      else
        symbols(path)
      end
    end)
  )
  return function()
    cancelled = true
    if process and not process:is_closing() then
      pcall(process.kill, process, 15)
    end
    if placement then
      pcall(placement.close, placement)
    end
    if temporary then
      vim.fn.delete(temporary, "rf")
    end
    if api.nvim_buf_is_valid(ctx.buf) then
      api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
    end
    if api.nvim_win_is_valid(ctx.win) then
      vim.wo[ctx.win].number = number
    end
  end
end
return M
