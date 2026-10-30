local util = require("selection_tools.sources.util")

return function(opts)
  return {
    prompt = "Grep",
    cwd = vim.fn.fnamemodify(opts.cwd or vim.fn.getcwd(), ":p"),
    live = true,
    match = false,
    result_layout = "grep",
    syntax = { enabled = true },
    multi = true,
    preview = { enabled = true },
    format_item = util.format,
    highlight_item = function(item)
      return item.match_ranges
    end,
    finder = function(ctx)
      if ctx.query == "" then
        ctx.set_items({})
        ctx.done()
        return
      end
      return util.rg(opts, ctx, ctx.query)
    end,
    on_choice = util.jump,
  }
end
