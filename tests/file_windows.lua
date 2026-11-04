vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.hidden, vim.o.swapfile = true, false
local api, tools = vim.api, require("selection_tools")
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
fixture = assert(vim.uv.fs_realpath(fixture))
local file = fixture .. "/target |%.txt"
vim.fn.writefile({ "target" }, file)
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect(expected) .. " ~= " .. vim.inspect(actual))
end
local function picker()
  local p = tools.files({ cwd = fixture, query = "target", preview = { enabled = false } })
  assert(vim.wait(5000, function()
    return not p.loading and not p.matching
  end, 2))
  assert(not p.error, p.error)
  eq(1, #p.matches)
  return p
end
local editor, source = api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved source" })
vim.cmd("topleft vnew")
local sidebar, scratch = api.nvim_get_current_win(), api.nvim_get_current_buf()
vim.bo[scratch].buftype = "nofile"
vim.bo[scratch].bufhidden = "wipe"
vim.bo[scratch].filetype = "test-sidebar"
vim.wo[sidebar].winfixbuf = true
api.nvim_buf_set_lines(scratch, 0, -1, false, { "Files" })
local function intact()
  eq(scratch, api.nvim_win_get_buf(sidebar))
  eq({ "Files" }, api.nvim_buf_get_lines(scratch, 0, -1, false))
end

-- Cancellation keeps the actual caller, confirmation chooses the editor.
local p = picker()
eq(sidebar, p.origin_win)
p:close()
eq(sidebar, api.nvim_get_current_win())
intact()
p = picker()
p:confirm()
eq(editor, api.nvim_get_current_win())
eq(file, api.nvim_buf_get_name(0))
eq({ "unsaved source" }, api.nvim_buf_get_lines(source, 0, -1, false))
assert(vim.bo[source].modified)
intact()

-- Prefer the editor active immediately before focusing the sidebar.
vim.cmd("rightbelow vnew")
local second = api.nvim_get_current_win()
api.nvim_set_current_win(sidebar)
p = picker()
p:confirm()
eq(second, api.nvim_get_current_win())
intact()

-- Resuming from an ordinary editor uses the new caller, not the old target.
api.nvim_set_current_win(editor)
p = tools.resume()
p:confirm()
eq(editor, api.nvim_get_current_win())
intact()
api.nvim_set_current_win(second)

-- Buffers and location sources use the same routing, including exact columns.
api.nvim_set_current_win(sidebar)
p = tools.buffers({ query = "target", preview = { enabled = false } })
assert(vim.wait(5000, function()
  return not p.matching
end, 2))
p:confirm()
eq(second, api.nvim_get_current_win())
intact()
api.nvim_set_current_win(sidebar)
require("selection_tools.sources.util").jump({ file = file, pos = { 1, 2 } })
eq(second, api.nvim_get_current_win())
eq({ 1, 2 }, api.nvim_win_get_cursor(0))
intact()

-- A target may disappear while selection is open. Create only on confirmation.
api.nvim_set_current_win(sidebar)
p = picker()
api.nvim_win_close(editor, true)
api.nvim_win_close(second, true)
p:close()
eq(sidebar, api.nvim_get_current_win())
eq(1, #api.nvim_tabpage_list_wins(0))
p = picker()
p:confirm()
local replacement = api.nvim_get_current_win()
assert(replacement ~= sidebar)
eq(2, #api.nvim_tabpage_list_wins(0))
eq(file, api.nvim_buf_get_name(0))
assert(api.nvim_win_get_position(replacement)[2] > api.nvim_win_get_position(sidebar)[2])
intact()

-- Explicit splits/tabs open from the editor, preserving the sidebar.
for _, mode in ipairs({ "split", "vsplit", "tab" }) do
  api.nvim_set_current_win(sidebar)
  local count = #api.nvim_list_wins()
  p = picker()
  require("selection_tools.actions").edit(p, mode)
  assert(api.nvim_get_current_win() ~= sidebar)
  eq(file, api.nvim_buf_get_name(0))
  eq(count + 1, #api.nvim_list_wins())
  intact()
  if mode == "tab" then
    vim.cmd("tabclose!")
  else
    vim.cmd("close!")
  end
end

-- An unlocked scratch window is a fallback target without plugin metadata.
local start = api.nvim_create_buf(false, true)
vim.bo[start].bufhidden = "wipe"
api.nvim_win_set_buf(replacement, start)
api.nvim_set_current_win(sidebar)
p = picker()
p:close()
eq(sidebar, api.nvim_get_current_win())
eq(start, api.nvim_win_get_buf(replacement))
eq(2, #api.nvim_tabpage_list_wins(0))

-- An ordinary editor is preferred even when the transient UI was last active.
vim.cmd("rightbelow vnew")
local ordinary = api.nvim_get_current_win()
api.nvim_set_current_win(replacement)
api.nvim_set_current_win(sidebar)
p = picker()
p:confirm()
eq(ordinary, api.nvim_get_current_win())
eq(start, api.nvim_win_get_buf(replacement))
api.nvim_win_close(ordinary, true)

local leaves = 0
local group = api.nvim_create_augroup("FileTargetReplaceable", { clear = true })
api.nvim_create_autocmd("BufWinLeave", {
  group = group,
  buffer = start,
  callback = function()
    leaves = leaves + 1
  end,
})
for _, mode in ipairs({ "split", "vsplit", "tab" }) do
  api.nvim_set_current_win(sidebar)
  p = picker()
  require("selection_tools.actions").edit(p, mode)
  eq(file, api.nvim_buf_get_name(0))
  eq(start, api.nvim_win_get_buf(replacement))
  eq(0, leaves)
  if mode == "tab" then
    vim.cmd("tabclose!")
  else
    vim.cmd("close!")
  end
end
api.nvim_del_augroup_by_id(group)

api.nvim_set_current_win(sidebar)
p = picker()
p:confirm()
eq(replacement, api.nvim_get_current_win())
eq(file, api.nvim_buf_get_name(0))
eq(2, #api.nvim_tabpage_list_wins(0))
assert(not api.nvim_buf_is_valid(start))
intact()

if vim.fn.exists("+winfixbuf") == 1 then
  vim.wo[replacement].winfixbuf = true
  api.nvim_set_current_win(sidebar)
  p = picker()
  p:confirm()
  assert(api.nvim_get_current_win() ~= replacement and api.nvim_get_current_win() ~= sidebar)
  eq(file, api.nvim_buf_get_name(0))
  intact()
end
-- Buffer kinds with their own interaction remain excluded even when unlocked.
local targets = require("selection_tools.sources.util")
for _, kind in ipairs({ "quickfix", "prompt", "help", "terminal" }) do
  vim.cmd("botright new")
  local excluded = api.nvim_get_current_win()
  if kind == "terminal" then
    api.nvim_open_term(0, {})
  else
    vim.bo.buftype = kind
  end
  assert(targets.file_window(excluded) ~= excluded, "selected " .. kind .. " as a file target")
  api.nvim_win_close(excluded, true)
end
vim.cmd("botright new")
local preview = api.nvim_get_current_win()
vim.wo.previewwindow = true
assert(targets.file_window(preview) ~= preview)
api.nvim_win_close(preview, true)
local float = api.nvim_open_win(api.nvim_create_buf(false, true), true, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 12,
  height = 2,
})
assert(targets.file_window(float) ~= float)
api.nvim_win_close(float, true)

-- A preferred window in another tab must never steal the current tab's file.
local remote = api.nvim_get_current_win()
vim.cmd("tabnew")
local local_win = api.nvim_get_current_win()
eq(local_win, targets.file_window(remote))
vim.cmd("tabclose!")

vim.fn.delete(fixture, "rf")
print(
  "file targets: sidebar cancellation, editor reuse, buffers, locations, stale targets, splits/tabs, unlocked scratch windows and native protection passed"
)
vim.cmd("qa!")
