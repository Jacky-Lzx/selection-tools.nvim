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
vim.fn.mkdir(fixture, "p")
fixture = vim.uv.fs_realpath(fixture)
local command = fixture .. "/emit.py"
vim.fn.writefile(
  vim.split(
    [=[#!/usr/bin/env python3
import json,os,sys,time,signal
from pathlib import Path
query=sys.argv[sys.argv.index('-e')+1]
def stop(*args):
    Path('stopped-'+query).write_text('stopped')
    sys.exit(0)
signal.signal(signal.SIGTERM,stop)
if query=='invalid':
    os.write(1,b'not json\n');sys.exit(0)
for i in range(1,13):
    code='中文 needle '+str(i)
    event={'type':'match','data':{'path':{'text':query+'中文.lua'},'line_number':i,'lines':{'text':code},'submatches':[{'start':7,'end':13,'match':{'text':'needle'}}]}}
    data=(json.dumps(event,ensure_ascii=False)+'\n').encode()
    os.write(1,data[:11]);os.write(1,data[11:])
    if query=='slow' and i==2: time.sleep(.3)
    if query=='flood': time.sleep(.03)
]=],
    "\n",
    { plain = true }
  ),
  command
)
vim.fn.setfperm(command, "rwx------")
local function grep(query, opts)
  local spec = vim.tbl_extend("force", {
    cwd = fixture,
    command = command,
    query = query,
    debounce_ms = 0,
    syntax = { enabled = false },
    preview = { enabled = false },
  }, opts or {})
  return tools.grep(spec)
end

test("grep publishes results before exit and appends preserve cursor, marks and objects", function()
  local p = grep("slow")
  assert(vim.wait(3000, function()
    return #p.matches >= 2 and p.loading
  end, 2))
  p:move(1)
  p:toggle()
  local item = p:current()
  ready(p)
  eq(#p.matches, 12)
  assert(p:current() == item)
  eq(p:selected(), { item })
  eq(item.code, "中文 needle 2")
  p:close()
end)
test("query replacement and close cancel streaming producers and discard late chunks", function()
  local p = grep("slow")
  assert(vim.wait(3000, function()
    return #p.matches >= 2 and p.loading
  end, 2))
  p:set_query("other")
  ready(p)
  eq(#p.matches, 12)
  for _, entry in ipairs(p.matches) do
    assert(entry.item.file:find("other中文.lua", 1, true))
  end
  p:close()
  p = grep("flood")
  assert(vim.wait(3000, function()
    return #p.matches > 0 and p.loading
  end, 2))
  p:close()
  assert(vim.wait(3000, function()
    return vim.fn.filereadable(fixture .. "/stopped-flood") == 1
  end, 2))
  assert(p.closed)
end)
test("result limits stop producers and expose explicit truncation state", function()
  local p = grep("flood", { limit = 3 })
  ready(p)
  eq(#p.matches, 3)
  eq(p.truncated, "result limit")
  assert(vim.wait(3000, function()
    return vim.fn.filereadable(fixture .. "/stopped-flood") == 1
  end, 2))
  p:close()
end)
test("output and line budgets bound memory without decoding partial JSON", function()
  local p = grep("other", { max_output = 450 })
  ready(p)
  eq(p.truncated, "output size limit")
  assert(not p.error and #p.matches < 12)
  p:close()
  p = grep("other", { max_line_bytes = 32 })
  ready(p)
  eq(p.truncated, "line size limit")
  eq(#p.matches, 0)
  p:close()
  p = grep("invalid")
  assert(vim.wait(3000, function()
    return not p.loading
  end, 2))
  assert(p.error)
  p:close()
end)
vim.fn.delete(fixture, "rf")
print(("%d streaming tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
