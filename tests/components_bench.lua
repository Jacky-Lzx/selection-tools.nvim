-- Reproducible local comparison, not a hardware-dependent pass/fail threshold.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
local tools, C = require("selection_tools"), require("selection_tools.components")
local count = tonumber(vim.env.SELECTION_TOOLS_BENCH_ITEMS) or 50000
local items = {}
for i = 1, count do
  local name = ("src/module_%05d/%s.lua"):format(i, i % 10 == 0 and "needle" or "ordinary")
  items[i] = { file = name, text = name }
end
local function elapsed(start)
  return (vim.uv.hrtime() - start) / 1e6
end
local function median(values)
  table.sort(values)
  return values[math.ceil(#values / 2)]
end
for _, mode in ipairs({ "legacy", "components", "decorated" }) do
  local samples = { open = {}, query = {}, move = {}, heap = {} }
  local calls, visible = 0, 0
  for _ = 1, 5 do
    collectgarbage("collect")
    local heap = collectgarbage("count")
    local opts = {
      items = items,
      resume = false,
      preview = { enabled = false },
      layout = { width = 80, height = 15 },
      matcher = { backend = "native" },
      format_icon = function()
        return "L", "Special"
      end,
      format_item = function(item)
        return item.text
      end,
    }
    if mode ~= "legacy" then
      opts.components = { C.icon(), C.path({ field = "text", path_format = false }) }
      if mode == "decorated" then
        opts.components[#opts.components + 1] = C.text({
          searchable = false,
          get = function()
            calls = calls + 1
            return "cached"
          end,
        })
      end
    end
    local start = vim.uv.hrtime()
    local p = tools.open(opts)
    samples.open[#samples.open + 1] = elapsed(start)
    visible = visible + p.height
    collectgarbage("collect")
    samples.heap[#samples.heap + 1] = (collectgarbage("count") - heap) / 1024
    start = vim.uv.hrtime()
    p:set_query("needle")
    samples.query[#samples.query + 1] = elapsed(start)
    start = vim.uv.hrtime()
    for _ = 1, 50 do
      p:move(1)
    end
    samples.move[#samples.move + 1] = elapsed(start) / 50
    p:close()
    tools.dispose()
  end
  print(
    ("%s: N=%d, open=%.2f ms, first query=%.2f ms, move=%.3f ms, Lua heap=%.2f MiB, decoration calls=%d (initial visible=%d)"):format(
      mode,
      count,
      median(samples.open),
      median(samples.query),
      median(samples.move),
      median(samples.heap),
      calls,
      visible
    )
  )
end
vim.cmd("qa!")
