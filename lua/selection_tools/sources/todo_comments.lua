local util = require("selection_tools.sources.util")

return function(opts)
  local keywords = opts.keywords
  if not keywords then
    local config = package.loaded["todo-comments.config"]
    local definitions = config and config.options and config.options.keywords
    keywords = {}
    if definitions then
      for name, definition in pairs(definitions) do
        keywords[#keywords + 1] = name
        vim.list_extend(keywords, definition.alt or {})
      end
    else
      keywords = {
        "TODO",
        "FIX",
        "FIXME",
        "BUG",
        "FIXIT",
        "ISSUE",
        "HACK",
        "WARN",
        "WARNING",
        "PERF",
        "OPTIM",
        "OPTIMIZE",
        "NOTE",
        "INFO",
        "TEST",
        "TESTING",
        "PASSED",
        "FAILED",
      }
    end
  end
  local escaped = {}
  for _, keyword in ipairs(keywords) do
    assert(keyword:match("^[%w_%-]+$"), "selection-tools: invalid TODO keyword")
    escaped[#escaped + 1] = keyword
  end
  table.sort(escaped)
  return {
    prompt = "TODO comments",
    cwd = vim.fn.fnamemodify(opts.cwd or vim.fn.getcwd(), ":p"),
    multi = true,
    preview = { enabled = true },
    format_item = util.format,
    finder = function(ctx)
      if #escaped == 0 then
        ctx.set_items({})
        ctx.done()
        return
      end
      local search = vim.tbl_extend("force", {}, opts, { regex = true })
      return util.rg(search, ctx, "\\b(" .. table.concat(escaped, "|") .. ")\\s*:", function(item)
        item.keyword = item.match_text:match("^([%w_%-]+)")
        return item
      end)
    end,
    on_choice = util.jump,
  }
end
