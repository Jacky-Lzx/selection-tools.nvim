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
if vim.fn.executable("chafa") ~= 1 or vim.fn.executable("rsvg-convert") ~= 1 or vim.fn.executable("pdftoppm") ~= 1 then
  print("SKIP image integration: requires chafa, rsvg-convert and pdftoppm")
  vim.cmd.qa()
  return
end
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
fixture = vim.uv.fs_realpath(fixture)
local svg = fixture .. "/plot | %.svg"
vim.fn.writefile({
  '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="40" height="40" fill="red"/><rect x="40" width="40" height="40" fill="blue"/></svg>',
}, svg)
local png = fixture .. "/plot | %.png"
assert(vim.system({ "rsvg-convert", "--output", png, svg }):wait().code == 0)
local pdf = fixture .. "/first page.pdf"
local pdf_script = [=[import sys
parts=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 160 80] /Contents 4 0 R >>']
stream=b'1 0 0 rg 0 0 80 80 re f 0 0 1 rg 80 0 80 80 re f'
parts.append(b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream')
data=b'%PDF-1.4\n'; offsets=[]
for i,part in enumerate(parts,1):
 offsets.append(len(data)); data+=str(i).encode()+b' 0 obj\n'+part+b'\nendobj\n'
xref=len(data); data+=b'xref\n0 5\n0000000000 65535 f \n'
for offset in offsets: data+=('%010d 00000 n \n'%offset).encode()
data+=b'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF\n'
open(sys.argv[1],'wb').write(data)
]=]
assert(vim.system({ "python3", "-c", pdf_script, pdf }):wait().code == 0)
local function preview(path, image)
  if image == nil then
    image = { backend = "chafa" }
  end
  return tools.open({
    items = { { file = path, text = path } },
    format_item = function(item)
      return item.text
    end,
    preview = { enabled = true, image = image },
    layout = { width = 0.95, height = 0.9 },
  })
end
local function wait_image(p)
  assert(
    vim.wait(10000, function()
      local ns = vim.api.nvim_get_namespaces().selection_tools_image
      return ns and #vim.api.nvim_buf_get_extmarks(p.preview_buf, ns, 0, -1, {}) > 0
    end, 5),
    table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
  )
end
test("PNG, SVG and first-page PDF previews render real colored symbols within the pane", function()
  for _, path in ipairs({ png, svg, pdf }) do
    local p = preview(path)
    wait_image(p)
    assert(not vim.wo[p.preview_win].number)
    local lines = vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false)
    assert(#lines <= vim.api.nvim_win_get_height(p.preview_win))
    for _, line in ipairs(lines) do
      assert(not line:find("\27", 1, true) and vim.fn.strwidth(line) <= p.resolved.width)
    end
    local buf = p.preview_buf
    p:close()
    assert(not vim.api.nvim_buf_is_valid(buf))
  end
end)
test("image limits and disabled rendering preserve predictable fallbacks", function()
  local p = preview(png, { backend = "chafa", max_size = 1 })
  assert(vim.wait(2000, function()
    return table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false)):find("size limit", 1, true)
  end, 2))
  p:close()
  p = preview(svg, false)
  assert(vim.wait(2000, function()
    return table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false)):find("<svg", 1, true)
  end, 2))
  p:close()
end)
test("cancelling conversion cannot paint the next text item", function()
  local text = fixture .. "/next.txt"
  vim.fn.writefile({ "plain text next" }, text)
  local p = tools.open({
    items = { { file = svg }, { file = text } },
    format_item = function(item)
      return item.file
    end,
    preview = { enabled = true, image = { backend = "chafa" } },
  })
  p:move(1)
  assert(vim.wait(3000, function()
    return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "plain text next"
  end, 2))
  vim.wait(200, function()
    return false
  end, 5)
  eq(vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1], "plain text next")
  assert(vim.wo[p.preview_win].number)
  p:close()
end)
test("symbol decoder retains colors without placing raw control bytes in buffers", function()
  local lines, spans = require("selection_tools.image").decode("\27[31mred\27[0m text\n\27[48;5;4m  \27[0m\n")
  eq(lines, { "red text", "  " })
  eq(spans[1].fg, 1)
  eq(spans[2].bg, 4)
end)
test("optional native image placements are closed exactly once", function()
  local snacks, uis = _G.Snacks, vim.api.nvim_list_uis
  local placed, closed = 0, 0
  _G.Snacks = {
    image = {
      supports = function()
        return true
      end,
      placement = {
        new = function(buf, path)
          assert(vim.api.nvim_buf_is_valid(buf) and path == png)
          placed = placed + 1
          return {
            close = function()
              closed = closed + 1
            end,
          }
        end,
      },
    },
  }
  vim.api.nvim_list_uis = function()
    return { {} }
  end
  local ok, err = pcall(function()
    local p = preview(png, { backend = "snacks" })
    assert(vim.wait(3000, function()
      return placed == 1
    end, 2))
    p:close()
    eq(closed, 1)
  end)
  _G.Snacks, vim.api.nvim_list_uis = snacks, uis
  assert(ok, err)
end)
vim.fn.delete(fixture, "rf")
print(("%d image tests passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cquit 1" or "qa!")
