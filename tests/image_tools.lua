vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.env.IMAGE_TOOLS_ROOT
if not root or not vim.uv.fs_stat(root .. "/lua/image_tools/init.lua") then
  print("SKIP image-tools integration (set IMAGE_TOOLS_ROOT)")
  return
end
vim.opt.runtimepath:append(root)
vim.o.swapfile = false
local requests = {}
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function(command)
    requests[#requests + 1] = command
  end,
  request = function(_, command, _, callback)
    requests[#requests + 1] = command
    local cancelled = false
    vim.schedule(function()
      if not cancelled then
        callback(nil)
      end
    end)
    return function()
      cancelled = true
    end
  end,
}
local tools = require("selection_tools")
local provider = require("selection_tools.integrations.image_tools").provider()
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local text = fixture .. "/text.txt"
vim.fn.writefile({ "plain fallback" }, text)
local image = root .. "/tests/fixtures/fixture.png"
local p = tools.open({
  items = { { file = text }, { file = image } },
  format_item = function(item)
    return item.file
  end,
  preview = { enabled = true, providers = { provider } },
  layout = { height = 0.9, width = 0.9 },
})
assert(vim.wait(3000, function()
  return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "plain fallback"
end, 2))
assert(not package.loaded.image_tools, "Text preview loaded image-tools")
local focus = p.input_win
p:move(1)
assert(
  vim.wait(5000, function()
    return p.preview.provider and p.preview.provider.id
  end, 2),
  table.concat(vim.api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
)
local view = p.preview.provider
assert(view.buf == p.preview_buf and view.win == p.preview_win and not vim.wo[p.preview_win].number)
assert(vim.api.nvim_get_current_win() == focus and not vim.bo[p.preview_buf].modifiable)
local placeholder = vim.fn.nr2char(0x10EEEE)
local line = vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1]
assert(line:sub(1, #placeholder) == placeholder, "Grid was overwritten by a delayed Loading write")
local api = require("image_tools")
local id = view.id
local uploads = api.status().terminal_cache.uploads
local oldheight = view.height
p:expand_preview()
assert(vim.wait(3000, function()
  return view.height ~= oldheight and view.session and view.session.stage == "ready"
end, 2))
assert(view.id == id and api.status().terminal_cache.uploads == uploads, "Resize uploaded pixels again")
p:move(1)
assert(vim.wait(3000, function()
  return vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "plain fallback"
end, 2))
assert(view.closed and vim.wo[p.preview_win].number and api.status().terminal_cache.placements == 0)
p:move(1)
assert(vim.wait(3000, function()
  return p.preview.provider and p.preview.provider.id
end, 2))
local last = p.preview.provider
local buf = p.preview_buf
assert(api.status().terminal_cache.uploads == uploads, "Warm return did not reuse pixels")
p:close()
assert(last.closed and not vim.api.nvim_buf_is_valid(buf) and api.status().terminal_cache.placements == 0)
assert(not package.loaded.snacks and not package.loaded["snacks.image"], "Integration pulled in Snacks")
api.clear_cache()
vim.fn.delete(fixture, "rf")
print(
  "PASS real image-tools API integration: lazy text fallback, borrowed pane, acknowledged placeholder draw, cached resize/reopen, focus and cleanup"
)
