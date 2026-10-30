# selection-tools.nvim

一个独立的 Neovim 搜索选择插件：提供可复用的搜索窗口与公开 API，并内置文件搜索和 buffer 列表。无需依赖 Snacks。

## 要求

- Neovim 0.10+
- 文件搜索需要 `fd` 或 `rg`（优先使用 `fd`）；普通列表选择无需外部程序
- 文件类型图标可选使用 `nvim-web-devicons`；Nerd Font 用于显示文件和目录字形
- 大列表可选使用 `sk`（skim），已验证 5.8.0；缺少或不兼容时自动回退原生匹配

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

直接输入可进行模糊搜索，使用 smart case（全小写查询忽略大小写，含大写字符时区分大小写）；`<C-n>` / `<Down>` 和 `<C-p>` / `<Up>` 移动，`<CR>` 确认，`<Esc>` / `<C-c>` 取消。结果列表中还支持普通模式 `j` / `k`，按 `/` 返回搜索框。没有匹配结果时，回车不会关闭窗口或选中其他条目。

```lua
local selection = require("selection_tools")
selection.files({ cwd = vim.fn.expand("~/project"), hidden = true, ignored = false })
selection.buffers({ current = false }) -- 排除当前 buffer
```

`cwd` 默认是调用时的当前目录。文件扫描异步执行，之后输入查询只筛选已有结果。默认遵守忽略规则，不包含隐藏文件；`.git` 目录始终排除。文件和 buffer 搜索默认启用预览、多选；支持实时全文搜索。

## 条目图标

文件、buffer、grep、最近文件等带文件位置的条目默认显示独立的图标列，项目目录显示文件夹图标。首次显示文件条目时按需加载可选的 `nvim-web-devicons`，使用其文件类型图标及高亮组；未安装时显示默认文件图标。仅为可见条目解析图标，并缓存本次候选的结果。

图标和多选标记均独立于搜索文本，不参与 native/skim 匹配、排序或复制路径。多选标记仅占一格，图标列按可见字形宽度对齐，列间留一格间距，支持窄字符、宽字符和 Emoji。

```lua
-- 全局关闭，也可以给 files()/buffers()/open() 等单次调用传入相同选项。
require("selection_tools").setup({ item_icons = { enabled = false } })

-- 自定义来源：返回字形和高亮组名称，nil 表示该项不显示图标。
require("selection_tools").open({
  item_icons = { enabled = true }, -- 本次调用开启图标
  items = { { text = "Lua task", icon = "λ", icon_hl = "Special" } },
  format_item = function(item) return item.text end,
  format_icon = function(item, original_index)
    return item.icon, item.icon_hl
  end,
})
```

`format_icon` 覆盖自动文件图标解析，同样只对可见条目调用。`item_icons = false` 也可关闭图标，包括自定义回调。这里的 `item_icons` 控制列表装饰，与 `icons()` 图标选择器的自定义目录选项 `icons` 分开。

## Grep 代码配色与预览定位

`<Space>sg` 默认采用双列布局：代码在左侧左对齐，文件路径和行列号在右侧右对齐。文件位置使用 `SelectionToolsFileLocation`（默认取 `Comment` 的前景色，无斜体），文件图标放在文件名右侧的固定宽度列中，逐行对齐。

列宽按终端显示单元计算，支持中文、宽字符及组合字符。长路径从左侧省略以保留文件名，长代码围绕首个命中截取并显示省略号；显示时去掉代码的前导空白。窄窗口逐步隐藏图标、行列号，极窄时只显示代码。省略后的语法及匹配高亮同步调整，原始内容、复制路径及跳转位置保持完整。可用 `grep({ result_layout = "plain" })` 恢复文件位置在前的布局。

`<Space>sg` 使用的 `grep()` 默认给条目中的代码应用 Tree-sitter 配色，沿用当前 runtime 的语言、注入及 `highlights` 查询。解析基于完整文件上下文，能区分跨行字符串中的文字和独立代码；文件名、行列号及图标保留各自样式，搜索命中继续叠加高亮。

只处理进入可见区域的文件和代码行，异步读取并复用解析结果；优先使用已加载 buffer 的未保存内容，不创建或修改源文件 buffer。磁盘缓存在新查询时检查元数据，buffer 缓存按 changedtick 更新。缺少语言解析器/查询或超过限制时保留普通文本及搜索高亮，不会自动安装解析器。

```lua
require("selection_tools").grep({
  syntax = { enabled = true, max_size = 1024 * 1024, max_lines = 10000, cache_size = 8 },
  preview = { highlight_line = true, highlight_matches = true },
})
```

`syntax.enabled = false` 关闭条目代码配色。文档缓存至少容纳可见行数量，避免多文件列表反复解析。预览中的当前结果行使用 `SelectionToolsPreviewLine`（默认 `CursorLine`），匹配内容使用 `SelectionToolsPreviewMatch`（默认 `Search`）；两者可分别关闭。预览切换会同步更新这些标记；如果 buffer 正文已与磁盘搜索结果不同，则不套用过期的匹配范围。

## 结果操作

`<C-q>` 将多选项（未多选时为全部过滤结果）发送到 Quickfix，`<C-l>` 发送到调用窗口的 Location list，并打开列表。只有文件位置条目会被导出；行列号与原始代码内容保留。可将 `keys.quickfix_all` / `keys.loclist_all` 配置为始终导出全部过滤结果。

`<C-x>` 水平分屏、`<C-v>` 垂直分屏、`<C-t>` 新 Tab 打开当前位置；多选时每项各开一个窗口或 Tab。文件、buffer、grep 和最近文件等位置条目均适用，保留未保存内容及行列位置。

## 搜索范围与模式

文件搜索和 grep 窗口内可用 `<A-h>` 切换隐藏文件、`<A-i>` 切换忽略文件、`<A-f>` 设置搜索目录、`<A-g>` 设置文件 glob（逗号分隔，`!` 排除，例如 `*.rs,!vendor/**`）。grep 另有 `<A-r>` 切换正则/字面模式、`<A-c>` 循环 smart/sensitive/ignore 大小写策略。状态显示在标题中；操作会保留输入、取消旧任务并重新搜索，`resume()` 保留这些选项。文件 glob 过滤需要 ripgrep。

也可调用 `picker:set_search_options({ cwd = "/project/src", globs = { "*.rs" }, case = "sensitive", regex = true })`，或在 `files()` / `grep()` 的调用选项中指定。

## 流式全文搜索

Grep 边接收 ripgrep JSON 边展示结果，分批解析时保持输入可响应；追加结果保留当前条目和多选标记。达到 `limit`（默认 10000）、`max_output`（默认 32 MiB）或 `max_line_bytes`（默认 1 MiB）后停止进程，右下角显示 `Limit reached`，具体原因可读取 `picker.truncated`。达到结果上限表示“上限已到”，不代表总命中数已知。新查询、切换选项及关闭窗口会取消旧进程并丢弃迟到的数据。

## 匹配后端

```lua
require("selection_tools").setup({
  matcher = {
    backend = "auto", -- "auto" / "native" / "skim"
    threshold = 50000,
    skim = {
      command = "sk",
      algorithm = "arinae",
      debounce_ms = 10,
      timeout_ms = 10000,
    },
  },
})
```

默认按候选总数切换：少于 5 万条用 Neovim 原生匹配，达到阈值后异步调用 skim。阈值可按机器和数据调整，不随当前命中数量来回切换。原生匹配只向 `matchfuzzypos()` 传递字符串，返回后映射回原始对象；同名条目仍保留各自的索引和对象身份。

skim 只负责过滤、排序，继续使用本插件的窗口、预览、多选和按键。候选数据编码后缓存；每次查询有独立的异步进程和代次，快速输入、清空查询、替换候选或关闭窗口都会取消旧任务，并忽略迟到的结果。大批结果分批解析，可见行才计算匹配高亮。处理期间显示 `Matching…` 并暂停确认，避免选到旧查询的结果。

两个引擎的评分与排名可能不同。为保留原来的字面、顺序匹配语义，包含空白、`! ^ $ | ' "`、反斜杠或超长查询时使用原生匹配，显式选择 `skim` 也遵循这一规则。空查询、空候选和 `match = false` 不启动 skim。缺少可执行文件时静默回退；执行失败、超时或返回异常时提醒一次，该 picker 后续使用原生匹配。用户的 `SKIM_DEFAULT_OPTIONS` 不会注入到匹配命令中。

可通过每次调用的 `matcher` 选项覆盖全局设置。`picker:matcher_status()` 返回 `{ backend = "none" | "native" | "skim", pending = boolean, error = string | nil }`，其中 `none` 表示无需本地匹配；`error` 记录最近的回退原因。

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

搜索源可通过 `highlight_item(item, original_index)` 返回 `{{start_byte, end_byte}, ...}`，为格式化条目的指定范围使用 `SelectionToolsMatch` 高亮。范围基于 `format_item` 返回的原始字符串，使用从 0 开始、右侧不包含的字节偏移；图标、多选标记和 Tab 等控制字符的显示转换由渲染器处理。回调仅对可见候选调用，结果缓存到候选被替换。grep 使用 ripgrep 返回的真实命中范围，不重新解释正则或进行模糊匹配。

返回的 picker 提供 `set_query(query)`、`set_items(items)`、`move(delta)`、`current()`、`confirm()` 和 `close()`。`current()` 返回当前条目及其原始索引；`close()` 表示取消。

预览可由搜索源扩展：`preview = { enabled = true }` 开启预览，`previewer(ctx)` 接收 `item`、`index`、`buf`、`win`、`is_cancelled()` 和 `set_lines(lines, filetype, title, position)`。`set_lines` 可从异步回调调用；previewer 可返回取消函数。`actions = { name = function(picker) ... end }` 可定义额外操作，再通过 `keys.name` 配置按键。

详见 `:help selection-tools`，包括配置、按键和完整 API。

## 验证

```sh
stylua --check lua plugin tests
nvim --headless -u NONE -n -i NONE -l tests/run.lua
nvim --headless -u NONE -n -i NONE -l tests/sources.lua
nvim --headless -u NONE -n -i NONE -l tests/lazy.lua
nvim --headless -u NONE -n -i NONE -l tests/item_icons.lua
nvim --headless -u NONE -n -i NONE -l tests/syntax.lua
nvim --headless -u NONE -n -i NONE -l tests/grep_columns.lua
nvim --headless -u NONE -n -i NONE -l tests/workflows.lua
nvim --headless -u NONE -n -i NONE -l tests/streaming.lua
python3 tests/tui.py
```

测试覆盖对象与索引保留、取消和生命周期、异步过期结果、文件搜索后端、各内置搜索源的确认行为和真实终端输入。图标目录的下载、缓存、失败及取消测试使用离线模拟。已安装 skim 时，还会运行真实 skim 测试，以及 6 万条候选的连续输入、预览和多选终端测试；未安装时跳过这些外部集成测试。终端测试使用 Python 标准库的 PTY，适用于 macOS/Linux。

## 内置搜索源

- `grep({ cwd, query, regex = false, hidden, ignored, limit = 10000 })`：实时全文搜索，默认按字面字符串搜索，使用 ripgrep 的 smart case；`regex = true` 开启正则。结果带行列位置，确认后跳转；列表高亮每行全部实际命中范围，支持字面搜索和正则匹配，空查询不扫描目录。

- `projects({ projects, dev, recent = true, max_depth = 2, open_files = true })`：合并当前项目、最近文件的项目根目录、显式目录和开发目录扫描；确认后切换工作目录并打开文件搜索。`open_files = false` 仅切换目录。

- `recent({ cwd, buffers = true })`：按最近使用顺序合并已列出的文件 buffer 和 `v:oldfiles`，跳过已删除文件并对路径别名去重；显式 `cwd` 可限定目录。

- `resume()` / `:SelectionTools resume`：恢复上次 picker 的搜索源、查询、选中位置、多选标记和预览滚动。静态列表保留原始对象，实时或未完成的搜索重新加载；`resume = false` 可禁用单个 picker 的记录。

- `todo_comments({ cwd, keywords })`：按 `KEYWORD:` 扫描 TODO 标记，默认包含 NOTE；若 todo-comments 已配置则读取其关键字与别名，也可显式限定关键字列表。独立使用不依赖 todo-comments 插件。

- `registers({ registers, register = "+" })`：搜索非空寄存器并预览多行内容，确认后复制内容和寄存器类型到目标寄存器；默认避免主动读取 OSC 52 剪贴板。

- `jumps()`：查看当前窗口的原生跳转列表，确认时按 jump list 索引执行原生前进/后退，保留后续跳转语义。

- `marks()`：合并当前 buffer 的局部标记与全局标记，显示并预览精确位置，确认后跳转。

- `undo()`：搜索原生撤销树（含分支），在独立克隆中生成版本差异预览；仅确认时更改原 buffer，若原内容已改变则拒绝套用旧状态。临时撤销文件和克隆在关闭时清理。

- `search_history()`：搜索历史选择会恢复搜索寄存器，并在原窗口执行所选搜索。

- `command_history()`：按最近顺序选择命令历史；确认后在原窗口执行命令。

- `qflist()`：选择 Quickfix 条目，预览文件并保留原生列表索引；列表变化后拒绝使用过期位置。

- `loclist()`：从调用窗口读取 Location list，并在该窗口跳转；不会读取 picker 窗口的列表。

- `commands()`：搜索内置、全局和当前缓冲区命令；默认填入命令行以便补充参数，execute=true 可直接执行。

- `autocmds()`：搜索事件、分组、pattern 和说明，预览完整定义；确认后定位 Lua 定义或打开只读详情。

- `keymaps()`：搜索全局及当前缓冲区各模式映射，预览定义；确认后沿用 Snacks 的 Normal 模式按键回放。action="definition" 可改为定位定义。

- `help()`：搜索 runtime 中的 help tags，预览定位到标签，确认后打开原生帮助文档。窗口显示后异步读取并分批解析；缓存按标签文件元数据及 runtime 顺序失效。

- `man()`：从 manpath 的本地手册目录索引页面，异步调用 man 预览，确认后用原生 :Man 打开；paths 可指定目录。

- `spelling()`：在原窗口替换光标处单词，保留其他同名词；原文发生变化后拒绝过期替换。沿用原 spelling 的上方输入、小窗口布局。

- `highlights()`：搜索高亮组，预览真实样式、链接和解析后的颜色属性；确认关闭，C-y 可复制名称。

- `icons()`：搜索 Nerd Fonts、Emoji、可选 devicons 和内置符号，确认后插入原 buffer。首次异步下载并缓存公开字形目录；icon_sources={} 禁用下载，icons 或 custom_sources 可提供本地目录。

所有搜索源均可通过 `pick(name, opts)`、同名 Lua 函数或 `:SelectionTools name` 调用。需要实时全文搜索的快捷键可调用 `grep({ regex = true })`，保持原 Snacks 正则搜索语义。

图标目录来自 [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) 和 [unicode-emoji-json](https://github.com/muan/unicode-emoji-json)，首次下载需要 curl；失败时仍可使用本地符号和 devicons。`custom_sources = { name = "/path/icons.json" }` 接受 `[{"icon":"λ","name":"lambda","category":"math"}]` 或 `[["λ","lambda"]]`。远程目录缓存位于 `stdpath("cache")/selection-tools/icons/`。

高亮属性、快捷键/自动命令定义和用户命令详情仅在预览当前项时生成；快捷键定义定位在一次 picker 中复用脚本索引，新 picker 会重新读取。

帮助、高亮、快捷键、自动命令、命令和项目搜索会先显示窗口，再分批准备候选；加载期间可继续输入或取消，候选完成后应用当前查询。项目扫描在一次加载内复用已找到及未找到的项目根目录。懒加载测试同时验证启动只注册轻量入口，以及真实终端中加载时的输入、取消、文件句柄清理和缓存复用。
