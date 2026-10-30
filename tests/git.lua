vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools = require("selection_tools")
local passed, failed = 0, 0
vim.notify = function() end
local function eq(a, b)
  assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function test(name, fn)
  local windows = vim.api.nvim_list_wins()
  local ok, err = xpcall(fn, debug.traceback)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not vim.tbl_contains(windows, win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.wait(10, function()
    return false
  end, 1)
  tools.setup()
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end
local function ready(p)
  assert(
    vim.wait(5000, function()
      return not p.loading and not p.matching
    end, 2),
    "source timed out"
  )
  assert(not p.error, p.error)
end
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/repo", "p")
fixture = vim.uv.fs_realpath(fixture)
local repo = fixture .. "/repo"
local function git(args)
  local command = { "git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-C", repo }
  vim.list_extend(command, args)
  local result = vim.system(command):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
git({ "init", "-q" })
git({ "config", "user.name", "Selection Test" })
git({ "config", "user.email", "selection@example.invalid" })
local name = "a | [x]%.txt"
vim.fn.writefile({ "first" }, repo .. "/" .. name)
vim.fn.writefile({ "deleted" }, repo .. "/deleted.txt")
vim.fn.writefile({ "local old = 1" }, repo .. "/old.lua")
git({ "add", "--all" })
git({ "commit", "-qm", "first subject" })
vim.fn.writefile({ "committed needle" }, repo .. "/" .. name)
git({ "add", "--all" })
git({ "commit", "-qm", "second needle" })
local head = git({ "rev-parse", "HEAD" })
vim.fn.writefile({ "staged needle" }, repo .. "/" .. name)
git({ "add", "--", name })
vim.fn.writefile({ "unstaged needle" }, repo .. "/" .. name)
git({ "mv", "--", "old.lua", "new [name].lua" })
vim.fn.delete(repo .. "/deleted.txt")
vim.fn.writefile({ "untracked needle" }, repo .. "/untracked\nname.lua")
local before = git({ "status", "--porcelain=v1", "-z", "--untracked-files=all" })
local function wait_preview(p, needle)
  assert(
    vim.wait(5000, function()
      return table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n"):find(needle, 1, true) ~= nil
    end, 2),
    table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
  )
end
local function choose(p, filename)
  for i, entry in ipairs(p.matches) do
    if entry.item.relative_file == filename then
      p:move(i - p.index)
      return entry.item
    end
  end
  error("Missing file: " .. filename)
end
test("Git status preserves literal filenames, renames and separate index/worktree diffs", function()
  local p = tools.git_diff({ cwd = repo })
  ready(p)
  eq(#p.matches, 4)
  local item = choose(p, name)
  assert(item.index_change and item.worktree_change)
  wait_preview(p, "+unstaged needle")
  local text = table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
  assert(
    text:find("# Staged", 1, true) and text:find("# Working tree", 1, true) and text:find("+staged needle", 1, true)
  )
  eq(vim.bo[p.preview_buf].filetype, "diff")
  item = choose(p, "new [name].lua")
  eq(item.old_file, "old.lua")
  wait_preview(p, "rename to new [name].lua")
  choose(p, "untracked\nname.lua")
  wait_preview(p, "+untracked needle")
  p:close()
  eq(git({ "status", "--porcelain=v1", "-z", "--untracked-files=all" }), before)
end)
test("staged filtering and deleted-file confirmation never recreate deleted paths", function()
  local p = tools.git_diff({ cwd = repo, staged = true })
  ready(p)
  eq(#p.matches, 2)
  for _, entry in ipairs(p.matches) do
    assert(entry.item.index_change and not entry.item.worktree_change)
  end
  p:close()
  p = tools.git_diff({ cwd = repo })
  ready(p)
  choose(p, "deleted.txt")
  p:confirm()
  assert(vim.bo.filetype == "diff" and vim.bo.readonly)
  assert(vim.wait(3000, function()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find("deleted", 1, true)
  end, 2))
  eq(vim.fn.filereadable(repo .. "/deleted.txt"), 0)
  vim.cmd.close()
end)
test("commit search and confirmation show read-only patches without checking out", function()
  local p = tools.git_log({ cwd = repo, query = "second needle" })
  ready(p)
  eq(#p.matches, 1)
  eq(p:current().commit, head:gsub("\n$", ""))
  wait_preview(p, "+committed needle")
  p:confirm()
  assert(vim.bo.filetype == "diff" and vim.bo.readonly)
  assert(vim.wait(3000, function()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find("+committed needle", 1, true)
  end, 2))
  eq(git({ "rev-parse", "HEAD" }), head)
  eq(git({ "status", "--porcelain=v1", "-z", "--untracked-files=all" }), before)
  vim.cmd.close()
end)
test("Git sources handle empty repositories, missing roots and bounded previews", function()
  local empty = fixture .. "/empty"
  vim.fn.mkdir(empty, "p")
  assert(vim.system({ "git", "-C", empty, "init", "-q" }):wait().code == 0)
  local p = tools.git_log({ cwd = empty })
  ready(p)
  eq(#p.matches, 0)
  p:close()
  p = tools.git_diff({ cwd = fixture })
  assert(vim.wait(3000, function()
    return not p.loading
  end, 2))
  assert(p.error)
  p:close()
  p = tools.git_log({ cwd = repo, max_lines = 3 })
  ready(p)
  wait_preview(p, "diff truncated")
  p:close()
end)
vim.fn.delete(fixture, "rf")
print(("%d git tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
