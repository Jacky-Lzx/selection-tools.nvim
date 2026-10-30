# selection-tools.nvim

一个独立的 Neovim 搜索选择插件：提供可复用的搜索窗口与公开 API，并内置文件搜索和 buffer 列表。无需依赖 Snacks。

## 要求

- Neovim 0.10+
- 文件搜索需要 `fd` 或 `rg`（优先使用 `fd`）；普通列表选择无需外部程序

## 安装与配置

当前本地开发目录可通过 lazy.nvim 加载：

```lua
{
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/selection-tools.nvim"),
  name = "selection-tools.nvim",
  main = "selection_tools",
  cmd = "SelectionTools",
  opts = {
    ui_select = false, -- 设为 true 后接管 vim.ui.select
    layout = { width = 0.6, height = 0.5, border = "rounded" },
  },
  keys = {
    { "<leader>sf", function() require("selection_tools").files() end, desc = "Find files" },
    { "<leader>sb", function() require("selection_tools").buffers() end, desc = "Buffers" },
  },
}
```

也可将本仓库添加到 `runtimepath`，直接调用 API；`setup()` 可省略。如果要接管 `vim.ui.select`，请确保插件在调用它之前加载，例如在上述配置中使用 `lazy = false`。

```lua
require("selection_tools").setup({ ui_select = true })
```

默认不会接管现有的 `vim.ui.select`，也不会修改 Snacks 或全局快捷键。若同时启用了其他 `vim.ui.select` 实现，以最后设置的实现为准。

## 使用

```vim
:SelectionTools files
:SelectionTools buffers
:SelectionTools
```

不带参数时默认搜索文件，支持搜索源名称补全。

直接输入可进行不区分大小写的模糊搜索；`<C-n>` / `<Down>` 和 `<C-p>` / `<Up>` 移动，`<CR>` 确认，`<Esc>` / `<C-c>` 取消。结果列表中还支持普通模式 `j` / `k`，按 `/` 返回搜索框。没有匹配结果时，回车不会关闭窗口或选中其他条目。

```lua
local selection = require("selection_tools")
selection.files({ cwd = vim.fn.expand("~/project"), hidden = true, ignored = false })
selection.buffers({ current = false }) -- 排除当前 buffer
```

`cwd` 默认是调用时的当前目录。文件扫描异步执行，之后输入查询只筛选已有结果。默认遵守忽略规则，不包含隐藏文件；`.git` 目录始终排除。文件和 buffer 搜索默认启用预览、多选；全文搜索暂未内置。

## 窗口、预览与操作

下面的配置对应纵向的 Snacks picker：上方预览占 60%，中间反向列表，下方输入框。整个窗口宽 80%、高 90%，使用一个外框和内部分隔线，不绘制遮罩。匹配数 / 总数显示在输入框右侧；分隔线与外框相连，不显示预览文件名。预览显示绝对行号。

```lua
require("selection_tools").setup({
  ui_select = true,
  layout = {
    width = 0.8, min_width = 60, height = 0.9,
    border = "rounded", title_pos = "center",
    input_position = "bottom", reverse = true, preview_height = 0.6,
  },
  history = { persist = true, limit = 100 },
  keys = {
    next = { "<A-j>", "<C-n>", "<Down>" },
    previous = { "<A-k>", "<C-p>", "<Up>" },
    select_previous = { "<Tab>" },
    select_next = { "<S-Tab>" },
    history_back = { "<A-Up>" },
    history_forward = { "<A-Down>" },
    preview_up = { "<C-u>" }, preview_down = { "<C-d>" },
    list_up = { "<A-u>" }, list_down = { "<A-d>" },
    copy = { "<C-y>" }, system_open = { "<C-o>" },
    ignore = { "<C-j>", "<C-k>" },
  },
})
```

`next` / `previous` 按屏幕方向移动；`select_previous` / `select_next` 标记当前项后按候选排名移动。多选标记在本地筛选时保留，替换候选列表时清除。文件确认会将标记文件加入 buffer 列表并显示第一个；没有标记时打开当前项。复制和系统打开都优先作用于标记项，否则作用于当前项，执行后保留搜索窗口。

预览异步读取普通文件，带文件类型高亮；已加载 buffer 优先使用未保存内容。默认限制为 1 MiB、10000 行、每行 1000 字节；超大文件和二进制文件显示提示。切换条目和关闭窗口会使旧预览失效。预览滚动和列表翻页都保持搜索框焦点。

`select()` / `vim.ui.select` 默认使用独立的紧凑布局：输入框在上、正向列表在下、宽度 50%（80–100 列，自动适应窄屏）、高度 40%。可用 `setup({ select = { layout = ... } })` 配置。若调用者提供 `preview_item`，则展示该回调返回的 buffer，并保留其高亮；插件不会修改或主动删除调用者的 buffer。

查询历史按搜索源保存。默认只保存在会话内；启用 `history.persist` 后保存到 `stdpath("state")/selection-tools/history.json`，也可指定 `history.path`。向前浏览到末尾会恢复本次尚未提交的查询。

## 供其他插件调用

### 直接选择条目

`select()` 与 `vim.ui.select` 的基础调用约定一致，额外返回 picker 对象：

```lua
local actions = {
  { label = "Build", run = function() print("build") end },
  { label = "Test", run = function() print("test") end },
}

require("selection_tools").select(actions, {
  prompt = "Choose action",
  format_item = function(item) return item.label end,
}, function(item, original_index)
  if item then item.run() end
end)
```

筛选后仍返回原始 Lua 对象和原列表索引；取消时回调收到 `nil, nil`。每个窗口只调用一次回调，调用前会清理窗口并恢复原窗口焦点。打开新 picker 会取消已有 picker。`open()` 可通过 `multi = true` 启用多选；确认回调的第三个参数是标记条目列表（没有标记时包含当前项），前两个参数仍是当前条目和索引。

### 注册搜索源

```lua
local selection = require("selection_tools")

selection.register_source("tasks", function(opts)
  return {
    prompt = "Tasks",
    items = opts.tasks or { "build", "test", "check" },
    on_choice = function(item)
      if item then print("Selected: " .. item) end
    end,
  }
end)

selection.pick("tasks", { query = "te" })
-- 也可通过 :SelectionTools tasks 打开
```

搜索源可以是配置表，也可以是接收调用选项并返回配置表的函数。`pick(name, opts)` 的选项覆盖搜索源默认值。

### 异步或动态搜索

```lua
local picker = require("selection_tools").open({
  prompt = "Remote results",
  live = true, -- 每次查询变化时重新调用 finder；默认只调用一次
  match = false, -- 已由搜索源过滤和排序时关闭本地模糊匹配
  finder = function(ctx)
    local process = vim.system({ "my-search", ctx.query }, { text = true }, function(result)
      if ctx.is_cancelled() then return end
      if result.code ~= 0 then
        ctx.fail(result.stderr)
        return
      end
      ctx.set_items(vim.split(result.stdout, "\n", { trimempty = true }))
      ctx.done()
    end)
    return function()
      if not process:is_closing() then process:kill(15) end
    end
  end,
  on_choice = function(item)
    if item then print(item) end
  end,
})
```

`ctx.set_items()` 替换候选列表；`ctx.done()` 结束加载；`ctx.fail(message)` 显示错误。这些方法可直接从异步回调调用。关闭窗口或更新 live 查询时，会执行 finder 返回的取消函数，旧请求结果会被丢弃。live 源每次重启会清空旧候选，避免确认到旧查询结果。

返回的 picker 提供 `set_query(query)`、`set_items(items)`、`move(delta)`、`current()`、`confirm()` 和 `close()`。`current()` 返回当前条目及其原始索引；`close()` 表示取消。

预览可由搜索源扩展：`preview = { enabled = true }` 开启预览，`previewer(ctx)` 接收 `item`、`index`、`buf`、`win`、`is_cancelled()` 和 `set_lines(lines, filetype, title, position)`。`set_lines` 可从异步回调调用；previewer 可返回取消函数。`actions = { name = function(picker) ... end }` 可定义额外操作，再通过 `keys.name` 配置按键。

详见 `:help selection-tools`，包括配置、按键和完整 API。

## 验证

```sh
stylua --check lua plugin tests
nvim --headless -u NONE -n -i NONE -l tests/run.lua
python3 tests/tui.py
```

测试覆盖对象与索引保留、取消和生命周期、异步过期结果、文件搜索后端和真实终端输入。终端测试使用 Python 标准库的 PTY，适用于 macOS/Linux。
