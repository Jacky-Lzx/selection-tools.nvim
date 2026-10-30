local M = {}
-- Cheap preflight avoids loading a lazy image plugin for ordinary text files.
-- image-tools' public capability API remains authoritative once a candidate is found.
local extensions = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  avif = true,
  heic = true,
  bmp = true,
  tif = true,
  tiff = true,
  svg = true,
  pdf = true,
}
function M.provider(opts)
  opts = opts or {}
  return function(ctx)
    local path = ctx.path
    local ext = path and path:match("%.([^./]+)$")
    if not ext or not (opts.extensions or extensions)[ext:lower()] then
      return false
    end
    if ctx.source_buf and vim.api.nvim_buf_is_loaded(ctx.source_buf) and vim.bo[ctx.source_buf].modified then
      return false -- Keep the user's live text buffer authoritative.
    end
    local loaded, image = pcall(require, "image_tools")
    if not loaded then
      ctx.set_lines({ "Image preview requires image-tools.nvim" })
      return true
    end
    if type(image.render) ~= "function" or type(image.supports) ~= "function" then
      ctx.set_lines({ "image-tools.nvim needs the embedded render API" })
      return true
    end
    if not image.supports(path) then
      return false
    end
    -- Synchronous preparation precedes renderer ownership; no queued Loading write
    -- may run after image-tools has painted its first placeholder grid.
    if
      not ctx.paint(function(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading image…" })
      end, { title = vim.fs.basename(path) })
    then
      return true
    end
    local view, err = image.render({
      path = path,
      buf = ctx.buf,
      win = ctx.win,
      page = opts.page,
      upscale = opts.upscale,
      is_valid = function()
        return not ctx.is_cancelled()
      end,
      paint = function(draw)
        return ctx.paint(draw, { title = vim.fs.basename(path) })
      end,
      on_error = function(message)
        ctx.set_lines({ "Image preview: " .. tostring(message) })
      end,
    })
    if not view then
      ctx.set_lines({ "Image preview: " .. tostring(err) })
      return true
    end
    return view
  end
end
-- Ready-to-use callback for lazy plugin specs, without resolving dependencies early.
M.preview = M.provider()
return M
