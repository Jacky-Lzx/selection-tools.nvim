local util = require("selection_tools.sources.util")

return function(opts)
  local items, seen = {}, {}
  local cwd = opts.cwd and vim.uv.fs_realpath(opts.cwd)
  local function add(path)
    if not path or path == "" or path:match("^%w+://") then
      return
    end
    local real = vim.uv.fs_realpath(path)
    local stat = real and vim.uv.fs_stat(real)
    if not stat or stat.type ~= "file" or seen[real] then
      return
    end
    if cwd and real:sub(1, #cwd + 1) ~= cwd .. "/" then
      return
    end
    seen[real] = true
    items[#items + 1] = { file = real, text = vim.fn.fnamemodify(real, ":~:.") }
  end
  if opts.buffers ~= false then
    local buffers = vim.fn.getbufinfo({ buflisted = 1 })
    table.sort(buffers, function(a, b)
      if a.lastused == b.lastused then
        return a.bufnr < b.bufnr
      end
      return a.lastused > b.lastused
    end)
    for _, info in ipairs(buffers) do
      add(info.name)
    end
  end
  for _, path in ipairs(vim.v.oldfiles) do
    add(path)
  end
  return {
    prompt = "Recent files",
    items = items,
    multi = true,
    preview = { enabled = true },
    format_item = util.format,
    on_choice = util.jump,
  }
end
