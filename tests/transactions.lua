vim.opt.rtp:prepend(vim.fn.getcwd())
local api, tools = vim.api, require("selection_tools")
local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end
local origin = api.nvim_get_current_win()
local choices, closes, context = 0, {}, nil
local function open(guard)
  return tools.open({
    items = { "alpha", "beta" },
    resume = false,
    before_confirm = guard,
    on_choice = function(item)
      if item then
        choices = choices + 1
      end
    end,
    on_close = function(_, outcome)
      closes[#closes + 1] = outcome.reason
    end,
  })
end
local p = open(function()
  return false, "stale edit"
end)
p:confirm()
assert(not p.closed and choices == 0 and notices[#notices]:find("stale edit", 1, true))
p.opts.before_confirm = function()
  error("bad guard")
end
p:confirm()
assert(not p.closed and not p.confirmation)
p.opts.before_confirm = function()
  return true
end
p:confirm()
p:confirm()
assert(p.closed and choices == 1 and closes[#closes] == "confirm")
assert(api.nvim_get_current_win() == origin)
p = open(function(ctx)
  context = ctx
end)
p:confirm()
local old = context
p:move(1)
p:move(-1)
assert(not old.accept() and not p.closed)
p:confirm()
p:set_query("a")
assert(not context.accept())
p:confirm()
p:set_items({ "alpha", "beta" })
assert(not context.accept())
p:confirm()
assert(context.accept() and choices == 2)
p = open(function(ctx)
  context = ctx
end)
p:confirm()
p:close()
assert(not context.accept() and closes[#closes] == "cancel")

local ctx
p = tools.open({
  items = { "one", "two" },
  resume = false,
  preview = { enabled = true },
  previewer = function(value)
    ctx = value
    value.set_lines({ "plain" }, "diff")
    return true
  end,
})
vim.wait(20)
local owned = api.nvim_create_buf(false, true)
assert(ctx.set_buffer(owned, { owned = true, title = "ANSI" }))
local channel = api.nvim_open_term(owned, {})
api.nvim_chan_send(channel, "\27[32mgreen\27[0m\n")
p:move(1)
vim.wait(20)
assert(not api.nvim_buf_is_valid(owned) and api.nvim_win_get_buf(p.preview_win) == p.preview_buf)
local borrowed = api.nvim_create_buf(false, true)
assert(ctx.set_buffer(borrowed, { title = "Caller-owned" }))
p:close()
assert(api.nvim_buf_is_valid(borrowed))
local late = api.nvim_create_buf(false, true)
assert(not ctx.set_buffer(late, { owned = true }) and not api.nvim_buf_is_valid(late))
api.nvim_buf_delete(borrowed, { force = true })

local provider = require("selection_tools.providers.diff")
p = tools.open({
  items = { { lines = { "--- a", "+++ a", "@@ -1 +1 @@", "-old", "+new" } } },
  resume = false,
  preview = { enabled = true, providers = { provider.provider({ backend = "vim" }) } },
})
assert(vim.wait(500, function()
  return vim.bo[p.preview_buf].filetype == "diff"
end, 5))
assert(api.nvim_buf_get_lines(p.preview_buf, 4, 5, false)[1] == "+new")
p:close()
print(
  "selection transactions: guards, async cancellation, close reasons, owned ANSI frames and shared diff provider passed"
)
vim.cmd("qa!")
