vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:prepend(vim.env.GIT_TOOLS_DIR or vim.fs.dirname(vim.fn.getcwd()) .. "/git-tools.nvim")
vim.o.swapfile = false
local api = vim.api
local tools = require("selection_tools")
assert(require("git_tools.diff"))
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local function wait(predicate)
  assert(vim.wait(3000, predicate, 5), "Undo preview timed out")
end
local function open(opts)
  local p = tools.undo(opts)
  wait(function()
    return not p.loading
  end)
  return p
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function edit(text)
  vim.cmd("normal! i\007u\027gg0C" .. text .. "\027")
  return vim.fn.undotree().seq_cur
end
local function select(p, seq)
  for i, entry in ipairs(p.matches) do
    if entry.item.seq == seq then
      p.index = i
      p:_render()
      return entry.item
    end
  end
  error("Missing undo sequence " .. seq)
end
local function preview(p)
  return api.nvim_win_get_buf(p.preview_win)
end
local function patch(p)
  return table.concat(api.nvim_buf_get_lines(preview(p), 0, -1, false), "\n")
end

local ok, err = xpcall(function()
  vim.cmd.enew()
  api.nvim_buf_set_name(0, directory .. "/状态_é.lua")
  local source = api.nvim_get_current_buf()
  local base = edit("local value = 'saved'")
  vim.cmd("silent write")
  local abandoned = edit("local value = '旧分支'")
  vim.cmd("silent undo " .. base)
  local branch = edit("local value = '新分支'")
  local newest = edit("local value = 'newest'")
  vim.cmd("silent undo " .. branch)
  local original, tick = api.nvim_buf_get_lines(source, 0, -1, false), api.nvim_buf_get_changedtick(source)
  local function unchanged()
    eq(api.nvim_buf_get_lines(source, 0, -1, false), original)
    eq(api.nvim_buf_get_changedtick(source), tick)
    eq(api.nvim_buf_call(source, vim.fn.undotree).seq_cur, branch)
  end

  local p = open({ backend = "vim" })
  local entries = {}
  for _, entry in ipairs(p.entries) do
    entries[entry.item.seq] = entry.item
  end
  assert(entries[base].saved and entries[branch].current and not entries[newest].current)
  assert(entries[abandoned].branch ~= entries[branch].branch)
  eq(entries[abandoned].parent, base)
  eq(entries[branch].parent, base)
  eq(entries[newest].parent, branch)
  assert(entries[0].text:find("initial state", 1, true))
  local row = select(p, abandoned)
  wait(function()
    return vim.bo[preview(p)].filetype == "diff" and patch(p):find("旧分支", 1, true)
  end)
  assert(patch(p):find("--- undo-" .. base .. "/状态_é.lua", 1, true))
  assert(patch(p):find("-local value = 'saved'", 1, true))
  assert(not patch(p):find("新分支", 1, true), "Parent comparison accidentally used the current snapshot")
  assert(patch(p):find("+++ undo-" .. abandoned .. "/状态_é.lua", 1, true))
  local current_start = entries[branch].text:find("current", 1, true)
  eq(
    vim.fn.strdisplaywidth(entries[branch].text:sub(1, current_start - 1)),
    vim.fn.strdisplaywidth(row.text:sub(1, row.highlights[4][1]))
  )
  local marks = api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })
  assert(#marks > 0)
  local separators = table.concat(api.nvim_buf_get_lines(p.separator_buf, 0, -1, false), "\n")
  assert(separators:find(("Step #%d → #%d"):format(base, abandoned), 1, true))
  unchanged()
  select(p, branch)
  wait(function()
    return p.preview.displayed_item.seq == branch and patch(p):find("新分支", 1, true)
  end)
  assert(patch(p):find("-local value = 'saved'", 1, true))
  local index = p.index
  p.opts.actions.undo_compare(p)
  eq(p.opts.compare, "current")
  wait(function()
    return patch(p) == "Current version (no changes)"
  end)
  eq(p.index, index)
  p.opts.actions.undo_compare(p)
  wait(function()
    return p.preview_title:find("Step #", 1, true) and patch(p):find("新分支", 1, true)
  end)
  eq(p.opts.compare, "parent")
  eq(p.index, index)
  unchanged()
  p.opts.actions.undo_compare(p)
  p:close()
  p = tools.resume()
  wait(function()
    return not p.loading
  end)
  eq(p.opts.compare, "current")
  eq(p:current().seq, branch)
  unchanged()
  p:close()
  print(
    "PASS undo: parent previews, real branch ancestry, current comparison toggle and resume, isolated Unicode snapshots"
  )

  assert(vim.fn.executable("delta") == 1, "Install delta to run renderer integration")
  p = open({ backend = "delta" })
  select(p, abandoned)
  wait(function()
    return vim.bo[preview(p)].buftype == "terminal" and patch(p):find("旧分支", 1, true)
  end)
  local frame = preview(p)
  assert(not vim.wo[p.preview_win].number)
  assert(p.preview_title:find("delta", 1, true))
  assert(type(p.preview.provider.resize) == "function" and type(p.preview.provider.close) == "function")
  unchanged()
  p:close()
  assert(not api.nvim_buf_is_valid(frame), "Owned delta buffer leaked on close")
  print("PASS undo: real delta API rendering, provider lifecycle, frame cleanup, original undo position preserved")

  for _, opts in ipairs({
    { backend = "vim" },
    {},
    { backend = "delta", delta = { command = "selection-tools-missing-delta" } },
  }) do
    p = open(opts)
    select(p, abandoned)
    wait(function()
      return vim.bo[preview(p)].filetype == (opts.backend == "vim" and "diff" or "git-tools-diff")
        and patch(p):find("旧分支", 1, true)
    end)
    unchanged()
    p:close()
  end
  print("PASS undo: explicit native backend and missing delta fallback")

  p = open({ compare = "current" })
  select(p, branch)
  wait(function()
    return patch(p) == "Current version (no changes)"
  end)
  eq(vim.bo[preview(p)].filetype, "text")
  p:close()
  unchanged()

  p = open()
  select(p, abandoned)
  p:set_query("no-such-undo-version")
  wait(function()
    return #p.matches == 0 and patch(p) == "No preview"
  end)
  assert(not p.closed and api.nvim_win_is_valid(p.preview_win))
  p:close()
  unchanged()
  print("PASS undo: no-op state and cancellation during delta render, zero results keep the picker open")

  p = open({ backend = "vim" })
  select(p, abandoned)
  p:confirm()
  eq(api.nvim_buf_get_lines(source, 0, -1, false), { "local value = '旧分支'" })
  eq(vim.fn.undotree().seq_cur, abandoned)

  -- A new buffer has only its initial state, which is still previewable.
  vim.cmd("enew!")
  p = open()
  eq(#p.entries, 1)
  assert(p:current().seq == 0 and p:current().current)
  wait(function()
    return patch(p) == "Initial state (no parent change)"
  end)
  p:close()
  print("PASS undo: branch confirmation and empty initial history")

  -- Different undo blocks can arrive at exactly the same text. These are
  -- cumulative previews from one fixed current snapshot, not parent edits.
  vim.cmd("enew!")
  local first = edit("local value = 'same text'")
  local other = edit("local value = 'different text'")
  local repeated = edit("local value = 'same text'")
  edit("local value = 'current text'")
  local unchanged_lines = api.nvim_buf_get_lines(0, 0, -1, false)
  p = open({ backend = "vim", compare = "current" })
  local patches = {}
  for _, seq in ipairs({ first, other, repeated, first }) do
    select(p, seq)
    wait(function()
      return p.preview.displayed_item and p.preview.displayed_item.seq == seq and vim.bo[preview(p)].filetype == "diff"
    end)
    local lines = api.nvim_buf_get_lines(preview(p), 0, -1, false)
    assert(lines[2]:find("undo-" .. seq .. "/", 1, true), "Preview labels are stale")
    patches[seq] = table.concat(vim.list_slice(lines, 3), "\n")
  end
  eq(patches[first], patches[repeated])
  assert(patches[first] ~= patches[other], "Distinct text reused an old patch")
  p:close()
  eq(api.nvim_buf_get_lines(0, 0, -1, false), unchanged_lines)
  print(
    "PASS undo: repeated text in distinct undo blocks has equal cumulative hunks; different text and labels update correctly"
  )

  vim.cmd("enew!")
  edit("same text")
  local no_op = edit("same text")
  p = open()
  select(p, no_op)
  wait(function()
    return patch(p) == "No text changes in this step"
  end)
  assert(p.preview_title:find("Step #", 1, true))
  p:close()
  print("PASS undo: a genuine no-op undo block explicitly reports no step changes")

  vim.cmd("enew!")
  vim.bo.undolevels = 2
  for i = 1, 6 do
    edit("retained " .. i)
  end
  p = open({ backend = "vim" })
  local oldest = p.entries[#p.entries].item
  assert(oldest.seq > 0 and oldest.parent == nil)
  select(p, oldest.seq)
  wait(function()
    return p.preview.displayed_item.seq == oldest.seq and p.preview_title:find("no longer", 1, true)
  end)
  assert(patch(p):find("retained " .. oldest.seq, 1, true))
  p:close()
  vim.bo.undolevels = vim.o.undolevels
  print("PASS undo: pruned parent history shows an explicit snapshot fallback")
end, debug.traceback)
vim.fn.delete(directory, "rf")
if not ok then
  print(err)
end
vim.cmd(ok and "qa!" or "cquit 1")
