vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = assert(vim.env.IMAGE_TOOLS_ROOT)
vim.opt.runtimepath:append(root)
vim.o.swapfile, vim.o.termguicolors = false, true
-- Exercise the real media/cache/placement code; acknowledge Kitty requests in
-- this PTY, which does not render pixels. Screen checks cover placeholder output.
package.loaded["image_tools.terminal"] = {
  supports = function()
    return true
  end,
  cell_size = function()
    return { width = 10, height = 20 }
  end,
  write = function() end,
  request = function(_, _, _, callback)
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
local directory = assert(vim.env.SELECTION_TOOLS_TEST_DIR)
local text = directory .. "/text.txt"
vim.fn.writefile({ "plain text fallback" }, text)
local items = {
  { file = text },
  { file = root .. "/tests/fixtures/fixture.png" },
  { file = root .. "/tests/fixtures/fixture.pdf" },
}
local p = require("selection_tools").open({
  items = items,
  format_item = function(item)
    return vim.fs.basename(item.file)
  end,
  preview = { enabled = true, providers = { require("selection_tools.integrations.image_tools").provider() } },
  layout = { width = 0.95, height = 0.9 },
})
local phase, ticks, view, id, uploads = "start", 0, nil, nil, nil
local timer = assert(vim.uv.new_timer())
local function mark(value)
  vim.fn.writefile({ value }, directory .. "/stage")
end
local function finish(ok, message)
  timer:stop()
  timer:close()
  vim.fn.writefile(vim.split(message, "\n", { plain = true }), directory .. "/result")
  vim.cmd(ok and "qa!" or "cquit 1")
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(function()
      ticks = ticks + 1
      assert(ticks < 650, "Embedded terminal timeout at " .. phase)
      if phase == "start" and vim.api.nvim_get_mode().mode == "i" then
        assert(not package.loaded.image_tools)
        mark("move")
        phase = "image"
      elseif phase == "image" and p.preview.provider and p.preview.provider.id then
        view = p.preview.provider
        id = view.id
        uploads = require("image_tools").status().terminal_cache.uploads
        assert(view.win == p.preview_win and vim.api.nvim_get_current_win() == p.input_win)
        vim.cmd.redraw()
        local top, left = unpack(vim.api.nvim_win_get_position(p.preview_win))
        local placeholder = vim.fn.nr2char(0x10EEEE)
        assert(
          vim.fn.screenstring(top + 1, left + 1):sub(1, #placeholder) == placeholder,
          "Placeholder not visible in the borrowed pane"
        )
        assert(not vim.bo[p.preview_buf].modifiable and not vim.wo[p.preview_win].number)
        mark("expand")
        phase = "expanded"
      elseif phase == "expanded" and p.normal_preview_height and view.session and view.session.stage == "ready" then
        assert(view.id == id and require("image_tools").status().terminal_cache.uploads == uploads)
        mark("type_text")
        phase = "text"
      elseif
        phase == "text"
        and p.query == "text"
        and vim.api.nvim_buf_get_lines(p.preview_buf, 0, 1, false)[1] == "plain text fallback"
      then
        assert(view.closed and vim.wo[p.preview_win].number)
        assert(require("image_tools").status().terminal_cache.placements == 0)
        mark("clear_text")
        phase = "cleared"
      elseif phase == "cleared" and p.query == "" then
        mark("move_again")
        phase = "warm"
      elseif phase == "warm" and p.preview.provider and p.preview.provider.id then
        assert(require("image_tools").status().terminal_cache.uploads == uploads)
        mark("pdf")
        phase = "pdf"
      elseif
        phase == "pdf"
        and p.preview.provider
        and p.preview.provider.path:match("%.pdf$")
        and p.preview.provider.id
      then
        assert(vim.api.nvim_get_current_win() == p.input_win and vim.api.nvim_get_mode().mode == "i")
        view = p.preview.provider
        mark("cancel")
        phase = "closed"
      elseif phase == "closed" and p.closed then
        assert(view.closed and require("image_tools").status().terminal_cache.placements == 0)
        assert(not package.loaded.snacks and not package.loaded["snacks.image"])
        finish(
          true,
          "PASS terminal image-tools API: lazy PNG/PDF rendering in existing pane, visible acknowledged placeholders, F3 cached resize, filter/text fallback, warm reopen, focus and lease cleanup (pixel display simulated)"
        )
      end
    end, debug.traceback)
    if not ok then
      finish(false, err)
    end
  end)
)
