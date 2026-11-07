vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local tools = require("selection_tools")
local dir = vim.fn.tempname()
vim.o.columns = math.max(120, vim.fn.strdisplaywidth(dir) + 60)
vim.fn.mkdir(dir .. "/子目录_é", "p")
vim.fn.writefile({ "needle" }, dir .. "/a.lua")
local function ready(p)
  assert(vim.wait(5000, function()
    return not p.loading and not p.matching and not p.syntax_pending
  end, 5))
  assert(not p.error, p.error)
end
local function lines(p)
  return api.nvim_buf_get_lines(p.separator_buf, 0, -1, false)
end
local function check(p, preview)
  local title = api.nvim_win_get_config(p.frame_win).title
  assert(title[1][1] == " " .. p.opts.prompt .. " ", vim.inspect(title))
  local dividers = lines(p)
  assert(#dividers == #p.resolved.separators)
  local path_index = p.opts.layout.input_position == "bottom" and 1 or #dividers
  local filter_index = p.opts.layout.input_position == "bottom" and #dividers or 1
  local path = vim.fn.fnamemodify(p.opts.cwd, ":~")
  assert(dividers[path_index]:find(path, 1, true), vim.inspect(dividers))
  assert(dividers[filter_index]:find(p.opts.hidden and "hidden:on" or "hidden:off", 1, true))
  assert(dividers[filter_index]:find(p.opts.ignored and "ignore:off" or "ignore:on", 1, true))
  for i, win in ipairs(p.separator_wins) do
    assert(vim.fn.strdisplaywidth(dividers[i]) == api.nvim_win_get_width(win))
    assert(api.nvim_win_get_cursor(win)[1] == i)
  end
  if preview then
    assert(path_index ~= filter_index)
  end
end
for _, position in ipairs({ "top", "bottom" }) do
  for _, source in ipairs({ "files", "grep" }) do
    local p = tools[source]({
      cwd = dir,
      query = source == "grep" and "needle" or "",
      layout = { height = 0.9, width = 0.95, input_position = position },
    })
    ready(p)
    check(p, true)
    p:set_search_options({ hidden = true, ignored = true, globs = { "*.lua" } })
    ready(p)
    check(p, true)
    assert(table.concat(lines(p)):find("*.lua", 1, true))
    p:set_search_options({ cwd = "子目录_é" })
    ready(p)
    check(p, true)
    p:close()
    p = tools.resume()
    ready(p)
    check(p, true)
    local old = vim.o.columns
    vim.o.columns = 16
    p:resize()
    for _, line in ipairs(lines(p)) do
      assert(vim.fn.strdisplaywidth(line) == p.resolved.width + 2)
    end
    vim.o.columns = old
    p:resize()
    check(p, true)
    p:close()
  end
end
local p = tools.files({ cwd = dir, preview = { enabled = false }, layout = { width = 0.95 } })
ready(p)
check(p, false)
p:close()
p = tools.open({ cwd = dir, items = { "one" }, preview = { enabled = true }, layout = { height = 0.9, width = 0.95 } })
assert(table.concat(lines(p)):find(dir, 1, true))
p:close()
vim.fn.delete(dir, "rf")
print(
  "PASS picker border metadata: files/grep, flags, scope, resume, Unicode, narrow resize, no preview and custom sources"
)
vim.cmd.qa({ bang = true })
