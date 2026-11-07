# selection-tools.nvim

A standalone Neovim search and selection plugin with reusable picker windows, a public API, and built-in file and buffer sources. No Snacks dependency.

## Requirements

- Neovim 0.10+
- File search requires `fd` or `rg` (`fd` is preferred); ordinary list selection needs no external programs
- Optional `nvim-web-devicons` for filetype icons; a Nerd Font for file and directory glyphs
- Optional `sk` (skim) for large lists, tested with 5.8.0; automatically falls back to native matching if unavailable or incompatible

## Installation and configuration

Load the local development checkout with lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/selection-tools.nvim"),
  name = "selection-tools.nvim",
  main = "selection_tools",
  cmd = "SelectionTools",
  opts = {
    ui_select = false, -- Set to true to handle vim.ui.select
    layout = { width = 0.6, height = 0.5, border = "rounded" },
  },
  keys = {
    { "<leader>sf", function() require("selection_tools").files() end, desc = "Find files" },
    { "<leader>sb", function() require("selection_tools").buffers() end, desc = "Buffers" },
  },
}
```

You can also add this repository to `runtimepath` and call the API directly; `setup()` is optional. To handle `vim.ui.select`, load the plugin before any calls to it, for example by adding `lazy = false` to the configuration above.

```lua
require("selection_tools").setup({ ui_select = true })
```

By default, the plugin leaves the existing `vim.ui.select`, Snacks, and global keymaps unchanged. If multiple `vim.ui.select` implementations are enabled, the last one installed takes precedence.

## Usage

```vim
:SelectionTools files
:SelectionTools buffers
:SelectionTools
```

With no arguments, the command searches files. Source names support completion.

Type to fuzzy search with smart case: lowercase queries ignore case, while queries containing uppercase characters are case sensitive. Move with `<C-n>` / `<Down>` and `<C-p>` / `<Up>`, confirm with `<CR>`, and cancel with `<Esc>` / `<C-c>`. The results list also supports Normal mode `j` / `k`; press `/` to return to the search input. When there are no matches, Enter leaves the window open without selecting another item.

With Neovim mouse support enabled (`set mouse=a`), click a result to select it or drag across rows to browse. Double-click confirms through the usual confirmation validation; it follows Neovim's `mousetime` setting (a value of `0` disables double-clicks). Ctrl-click toggles a mark when multiple selection is enabled. The wheel over the list or search input moves three results in screen order without wrapping; over the preview or its scrollbar it scrolls three lines. These interactions preserve the search focus and mode. Click the input to position its cursor and resume editing from Normal-mode list navigation. Empty rows and borders do not confirm or close the picker. Clicking an editor outside the picker cancels and leaves that editor in Normal mode. Mouse mappings are local to picker buffers; the plugin does not change global mouse settings.

```lua
local selection = require("selection_tools")
selection.files({ cwd = vim.fn.expand("~/project"), hidden = true, ignored = false })
selection.buffers({ current = false }) -- Exclude the current buffer
```

Confirming files, buffers or file locations uses an editor in the same tab.
The current editor takes precedence, followed by the editor remembered before
file/buffer search, the alternate window and other ordinary windows. If none
remains, an unlocked `nofile` window (such as a dashboard) can be reused;
otherwise confirmation creates an editor to the right. Cancellation restores
the calling window without creating a split.

Persistent sidebars should set the native window option
`vim.wo[win].winfixbuf = true`. Protected windows, floating/preview windows,
terminals, quickfix and prompt buffers are never replacement targets. No
filetype names or cross-plugin buffer flags are needed. Explicit split/tab
actions keep scratch UI buffers in their original window.

`cwd` defaults to the working directory at the time of the call. File scanning runs asynchronously; subsequent queries filter the collected candidates. By default, scanning respects ignore rules and excludes hidden files; `.git` directories are always excluded. File and buffer pickers enable previews and multiple selection by default. Live full-text search is also available.

Asynchronous searches and matching do not show `Loading` / `Matching` messages. While typing, the current list and preview stay visible until new results are ready. The list stays empty during the initial wait and shows `No results` only after a search finishes without matches. Confirmation, split opening, and result export are paused until the first results of a new search arrive, preventing actions on items from the previous query.

## Item icons

Items with file locations, including files, buffers, grep results, and recent files, show a separate icon column by default. Project directories show folder icons. The optional `nvim-web-devicons` is loaded on demand when file items first appear, supplying filetype icons and highlight groups; a default file icon is used when it is unavailable. Icons are resolved only for visible items and cached for the current candidates.

Icons and selection marks are separate from searchable text and do not affect native/skim matching, ranking, or copied paths. Selection marks occupy one display cell. The icon column aligns by visible glyph width with one cell between columns, supporting narrow and wide characters and Emoji.

```lua
-- Disable globally, or pass the same option to individual files()/buffers()/open() calls.
require("selection_tools").setup({ item_icons = { enabled = false } })

-- Custom source: return a glyph and highlight group, or nil to omit the icon.
require("selection_tools").open({
  item_icons = { enabled = true }, -- Enable icons for this call
  items = { { text = "Lua task", icon = "λ", icon_hl = "Special" } },
  format_item = function(item) return item.text end,
  format_icon = function(item, original_index)
    return item.icon, item.icon_hl
  end,
})
```

`format_icon` overrides automatic file icon resolution and is called only for visible items. `item_icons = false` disables icons, including custom callbacks. This `item_icons` option controls list decorations and is separate from the `icons` option for custom catalogs in the `icons()` picker.

## Grep syntax colors and preview positions

`<Space>sg` uses separate columns for code, filenames, line/column positions, and icons by default. Code is left aligned; filenames and `line:column` positions are independently right aligned, with two spaces between them. Changes in the number of position digits do not shift filenames. File locations use `SelectionToolsFileLocation` (the `Comment` foreground without italics by default). File icons align in a fixed-width column at the far right.

Column widths use terminal display cells, supporting Chinese, wide, and combining characters. Long paths are truncated from the left to preserve filenames; long code is clipped around the first match with ellipses, and leading whitespace is removed for display. Narrow windows progressively hide icons and positions; very narrow windows show only code. Syntax and match highlights adjust to truncation, while original content, copied paths, and jump locations remain intact. Use `grep({ result_layout = "plain" })` to restore the layout with file locations first.

The `grep()` source used by `<Space>sg` applies Tree-sitter colors to result code by default, using the current runtime's languages, injections, and `highlights` queries. Parsing uses the full file context to distinguish text inside multiline strings from standalone code. Filenames, positions, and icons retain their own styles, with search highlights layered over the code.

Only visible files and code lines are processed, with asynchronous reads and reused parse results. Unsaved content in loaded buffers takes precedence; source buffers are neither created nor modified. Disk caches check metadata for each new query, and buffer caches update by changedtick. Missing parsers/queries or exceeded limits fall back to plain text with search highlights; parsers are not installed automatically.

Existing highlights remain visible during cache checks when the code content is unchanged. For new files or changed lines, the previous frame stays visible until syntax for the visible results is ready, then text and highlights update together to avoid briefly showing uncolored code. Confirmation, selection, copying, opening, and export are paused for results that have not yet been displayed.

```lua
require("selection_tools").grep({
  syntax = { enabled = true, max_size = 1024 * 1024, max_lines = 10000, cache_size = 8 },
  preview = { highlight_line = true, highlight_matches = true },
})
```

`syntax.enabled = false` disables result code colors. The document cache holds at least as many entries as there are visible rows to avoid repeatedly parsing lists spanning many files. The current result line in the preview uses `SelectionToolsPreviewLine` (`CursorLine` by default), and matched text uses `SelectionToolsPreviewMatch` (`Search` by default); each can be disabled separately. These marks update with the preview. Stale match ranges are not applied when buffer content differs from the disk search results.

## Result actions

`<C-q>` sends marked items, or all filtered results if none are marked, to Quickfix. `<C-l>` sends them to the calling window's Location list. Both open the target list. Only items with file locations are exported, preserving positions and original code. Configure `keys.quickfix_all` / `keys.loclist_all` to always export all filtered results.

`<C-x>` opens the current location in a horizontal split, `<C-v>` in a vertical split, and `<C-t>` in a new tab. Each marked item gets its own window or tab. These actions support location items from files, buffers, grep, recent files, and similar sources, preserving unsaved content and line/column positions.

`<F2>` opens read-only details for the current item, including the full path, position, and untruncated code or content. Text wraps, and native Normal mode scrolling and selection are available. `q` / `<Esc>` returns to the same picker with its query, current selection, and marks preserved; `<C-y>` in the details window copies the full content. `<F3>` temporarily enlarges an existing preview while retaining a few list rows; press it again to restore the original proportions.

## Search scope and modes

In file and grep pickers, `<A-h>` toggles hidden files, `<A-i>` toggles ignored files, `<A-f>` sets the search directory, and `<A-g>` sets file globs (comma separated, with `!` for exclusions, such as `*.rs,!vendor/**`). Grep also supports `<A-r>` to toggle regex/literal mode and `<A-c>` to cycle through smart/sensitive/ignore case policies. The top border shows the picker name, the preview/list divider shows the search directory, and the input/list divider shows the current filters (including `hidden:on/off` and `ignore:on/off`). Grep also shows its matching and case modes. Labels update when options change and follow `layout.title_pos`. Without a preview pane, the directory and filters share the input divider. Other pickers with `cwd` use the same directory divider; explicit preview titles retain their own divider. Changes preserve the query, cancel old work, and restart the search; `resume()` retains these options. File glob filtering requires ripgrep.

You can also call `picker:set_search_options({ cwd = "/project/src", globs = { "*.rs" }, case = "sensitive", regex = true })` or pass these options to `files()` / `grep()`.

## image-tools integration

The optional integration uses image-tools.nvim's public `supports()` / `render()` API. image-tools handles image conversion, caching, and terminal rendering; this plugin owns the preview window and its lifecycle. It does not call Snacks.image or bundle chafa or other image backends.

```lua
require("selection_tools").setup({
  preview = {
    providers = { require("selection_tools.integrations.image_tools").provider() },
  },
})
```

In a lazy.nvim `opts` table evaluated before the plugin loads, use a deferred callback: `providers = { function(ctx) return require("selection_tools.integrations.image_tools").preview(ctx) end }`.

The adapter loads image-tools only for candidates such as PNG, SVG, and PDF files. Ordinary text uses the standard preview, with loaded, unsaved text taking precedence. Images fit the preview area while preserving their aspect ratio. When switching images, the previous ready image stays visible until the new placement is acknowledged and drawn, then the old view is released to avoid Loading/blank flashes. Requests skipped by rapid navigation are still cancelled. Closing releases both current and retained views; `F3` and window resizing update existing views and reuse cached pixels. This requires an image-tools version with the embedded API and a terminal with supported image capabilities; errors appear in the preview. The integration is disabled by default and does not change preview priority for `vim.ui.select`.

Use `provider({ page = 2, upscale = false })` to set the PDF page and upscaling policy. `extensions` can supply additional extension mappings (such as `{ png=true, pdf=true }`) as an initial filter for loading the integration on demand; image-tools still determines actual format support.

## Preview providers

### Validation before confirmation and transactional pickers

`open()` / `select()` support `before_confirm(ctx)`. Return `true` to confirm and close,
or `false, message` to reject and keep the window open. Validation errors are also displayed without closing the window.
Return `nil` for asynchronous handling, then call `ctx.accept()` or `ctx.reject(message)` on the main thread.
`ctx` includes `picker/item/index/selected/is_cancelled()`; repeated confirmation is blocked while a confirmation is pending.
Changing the item or query, replacing candidates, or closing the window invalidates pending confirmation; a late
`accept()` returns `false`. Asynchronous callbacks must check `is_cancelled()` first and use `vim.schedule`
to return from a fast callback to the main thread.

For `on_close(picker, outcome)`, `outcome.reason` is `"confirm"` or `"cancel"`.
Existing single-argument callbacks remain compatible. Windows are cleaned up and focus is restored before `on_close` and `on_choice` run.
Transactional pickers should set `resume = false` to avoid restoring callbacks tied to old requests.

### External diff provider

```lua
require("selection_tools").open({
  prompt = "Review changes",
  items = { { text = "main.lua · 1 edit", lines = unified_diff_lines } },
  format_item = function(item) return item.text end,
  resume = false,
  preview = {
    enabled = true,
    providers = {
      require("git_tools.integrations.selection").diff({
        backend = "vim", -- Or delta; no Snacks dependency
        delta = { command = "delta", args = {}, timeout = 2000 },
      }),
    },
  },
  before_confirm = function(ctx)
    return validate_changes(ctx.item) -- true or false, message
  end,
  on_choice = function(item)
    if item then apply_changes() end
  end,
})
```

The standalone `git-tools.nvim` provides diff generation and native/delta rendering. Before using this example,
add git-tools.nvim to runtimepath; ordinary pickers do not need it installed or loaded.
The former `selection_tools.providers.diff` module has moved: use
`git_tools.integrations.selection.diff(opts)` for a provider and
`git_tools.diff.render(ctx, lines, opts, valid)` for direct rendering. Pass `opts.cwd` explicitly for direct calls.
selection-tools retains ownership of windows, focus, confirmation, and preview frame lifecycles; the caller validates and applies changes.

`ctx.set_buffer(buf, { owned = true, title = "Preview" })` installs a new preview frame.
The old frame remains until the new one is ready, then is released. Closing the window also releases owned buffers.
If `owned` is omitted, the buffer remains caller-owned and is never deleted. Stale owned frames are cleaned up.
The generic provider `ctx` also includes `picker`; `paint()` and `set_lines()` safely switch back to
the internal text buffer, supporting transitions between ANSI, images, and plain text.

### Custom providers

`preview.providers` calls each `function(ctx)` in order. Returning `false` / `nil` passes control to the next provider or the default file preview. Returning `true`, a cancellation function, or an object with `close()` and optional `resize()` takes ownership. Caller-supplied `preview_item` and source-supplied `previewer` callbacks retain priority.

`ctx` includes `item/index/path/source_buf/buf/win/is_cancelled()/set_lines()`. `ctx.paint(draw, { title = ... })` calls `draw(buf,win)` in a single main-thread transaction guarded against stale requests, supporting synchronous line writes and extmarks while automatically restoring the buffer's writable flag. Main-thread calls complete synchronously; fast callbacks schedule the whole transaction and discard stale work. Draw image placeholders with `paint` rather than adding highlights immediately after asynchronous `set_lines`. Resizing calls the returned object's `resize()`. When switching items, an object with `retain()` can return a handle that keeps only its ready display, passed to the next provider as `ctx.previous`; `ctx.has_preview` indicates existing content. The retained handle closes after new `paint` / `set_lines` work completes or on cancellation. Providers without retention support still have their cancellation function or `close()` called immediately.

## Streaming full-text search

Grep displays results as ripgrep JSON arrives, parsing in batches to keep input responsive. Appended results preserve the current item and selection marks. Reaching `limit` (10000 by default), `max_output` (32 MiB), or `max_line_bytes` (1 MiB) stops the process and shows `Limit reached` at the bottom right; `picker.truncated` records the reason. Reaching a limit does not establish the total number of matches. New queries, option changes, and window closure cancel old processes and discard late data.

## Matching backends

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

By default, the backend depends on the total candidate count: Neovim native matching below 50000 candidates, asynchronous skim at or above the threshold. Adjust the threshold for your machine and data; it does not switch back and forth with the current match count. Native matching passes only strings to `matchfuzzypos()` and maps results back to the original objects. Items with identical labels retain their own indices and object identities.

skim handles only filtering and ranking; this plugin still provides windows, previews, multiple selection, and key bindings. Encoded candidates are cached. Each query has a separate asynchronous process and generation; rapid typing, clearing the query, replacing candidates, or closing the window cancels old work and ignores late results. Large result sets are parsed in batches, with match highlights computed only for visible rows. The current list, selection, and preview remain visible during processing, and confirmation is paused to avoid selecting results from an old query.

The engines may produce different scores and rankings. To preserve the existing literal, ordered matching semantics, queries containing whitespace, `! ^ $ | ' "`, backslashes, or excessive length use native matching even when `skim` is explicitly selected. Empty queries, empty candidate lists, and `match = false` do not start skim. A missing executable silently falls back to native matching. Execution failures, timeouts, or malformed output trigger one warning, then that picker uses native matching for subsequent queries. The user's `SKIM_DEFAULT_OPTIONS` are not injected into the matching command.

Override global settings with the per-call `matcher` option. `picker:matcher_status()` returns `{ backend = "none" | "native" | "skim", pending = boolean, error = string | nil }`, where `none` means no local matching is needed and `error` records the most recent fallback reason.

## Windows, previews, and actions

The following configuration resembles a vertical Snacks picker: a preview occupying the top 60%, a reversed list in the middle, and input at the bottom. The overall window uses 80% width and 90% height, with a single outer border and internal separators, without a backdrop. The input shows the match/total count on the right. Separators connect to the border, the preview filename is hidden, and the preview shows absolute line numbers.

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

Each border label can override its text and alignment independently, globally in
`setup()` or per call in `open()`, `select()` and built-in pickers:

```lua
require("selection_tools").files({
  layout = {
    labels = {
      top = { text = "Files", align = "left" },
      middle = { align = "center" }, -- Keep the automatic path
      bottom = { align = "right" },  -- Keep the automatic filters
    },
  },
})
```

`top` names the outer top border; `middle` and `bottom` name the two internal
dividers in screen order. With bottom input these show the title, path and
filters, respectively. With top input the automatic filters/path swap dividers.
Without a preview there is only one divider, controlled by `bottom`; its default
combines the path and filters. `middle` is then absent.

Each `text` accepts a string, `false`/`""` to hide the label, or
`function(picker, default_text)` returning a string, `false`, or `nil` to keep the
automatic text. Callbacks run on redraw, including query, selection, option and
preview updates; keep them fast and free of side effects. Errors or invalid
results warn once per label and fall back to automatic text. Omit `text` to keep
the default; omit `align` to inherit `layout.title_pos` (or left alignment for a
specialized preview title). `align` accepts `"left"`, `"center"` and `"right"`.
Overrides also apply to specialized preview titles, such as Undo's comparison
label. Labels escape control characters; divider text clips to display cells
when space is limited.

For example, any custom source can show its current query with
`bottom = { text = function(p) return "Filter: " .. p.query end, align = "right" }`.

`next` / `previous` move in screen directions; `select_previous` / `select_next` mark the current item and then move by candidate rank. Marks survive local filtering and are cleared when candidates are replaced. Confirming files adds the marked files to the buffer list and displays the first one; without marks, it opens the current item. Copy and system-open actions prefer marked items, falling back to the current item, and leave the picker open.

Previews read ordinary files asynchronously with filetype highlighting, preferring unsaved content from loaded buffers. Default limits are 1 MiB, 10000 lines, and 1000 bytes per line; oversized and binary files show a message. Switching items or closing the window invalidates old previews. Preview scrolling and list paging keep focus in the search input.

Scrollable previews show a slim scrollbar over the right border and a percentage on the preview divider: `↓ 0%` at the top, `↑↓ 45%` between the ends, and `↑ 100%` at the bottom. Both hide when the content fits. The percentage describes travel through the loaded preview; previews limited by `max_lines` also show `truncated`. Images hide text scroll indicators. Normal text, caller-owned buffers and delta previews share this behavior, including provider-driven scrolling, F3 expansion, resizing and resume. Configure `preview = { scrollbar = false }` or `preview = { position = false }` to disable either indicator independently (both default to `true`). The scrollbar uses `SelectionToolsPreviewTrack` and `SelectionToolsPreviewThumb`; the percentage uses `SelectionToolsCount`.

`select()` / `vim.ui.select` use a separate compact layout by default: input on top, a forward list below, 50% width (80–100 columns, adapting to narrow screens), and 40% height. Configure it with `setup({ select = { layout = ... } })`. When the caller provides `preview_item`, the returned buffer is displayed with its highlights preserved; the plugin does not modify or proactively delete caller-owned buffers.

Query history is stored per source. By default it lasts only for the session. Enable `history.persist` to save it to `stdpath("state")/selection-tools/history.json`, or set `history.path`. Moving forward past the newest entry restores the draft query from before history browsing.

## API for other plugins

### Selecting items directly

`select()` follows the basic `vim.ui.select` calling convention and also returns a picker object:

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

Use `on_change(item, original_index, picker)` for live selection feedback, even
without a preview pane. It runs for the initial displayed selection and whenever
the displayed item or its original index changes; no matches supplies `nil, nil`.
Redraws/resizes of the same selection do not repeat it. Pending asynchronous
results retain the last displayed selection. Callback errors are reported while
the picker stays usable. Pair this with `before_confirm` and `on_close` for
transactional previews; set `resume = false` for callbacks tied to one session.

Filtering preserves the original Lua object and its index in the original list. Cancellation calls the callback with `nil, nil`. Each picker calls its callback once, after cleaning up windows and restoring the original focus. Opening a new picker cancels the existing one. Enable multiple selection in `open()` with `multi = true`; the confirmation callback's third argument is the list of marked items (or the current item if none are marked), while the first two remain the current item and its index.

Marking the first item reveals a selection column on the left: `○ │ item` is unmarked, and `● │ item` is marked. The column stays visible when filtering hides marked items and collapses after all marks are cleared.

Unmarked circles and separators use the theme's `Comment` gray; marked circles use the `Special` accent. Override them with `SelectionToolsUnmarked`, `SelectionToolsMarkSeparator`, and `SelectionToolsMarked`, respectively. When the selection column is hidden, one cell of padding remains to the left of icons.

### Composing result rows

Use `components` in `open()`, `select()`, or a registered source to share formatting,
styles, and column sizing. Descriptors can be reused across pickers; original
items still reach preview and confirmation callbacks unchanged.

```lua
local selection = require("selection_tools")
local C = require("selection_tools.components")

selection.setup({
  component_defaults = {
    path = { hl = "Directory" }, -- Defaults for every path component
    time = { format = "%H:%M", hl = "Comment" },
  },
})

selection.open({
  items = results,
  components = {
    C.icon(),
    C.path({ max_width = 30, grow = 0 }),
    C.position({ align = "right" }),
    C.text({ field = "message", grow = 1, truncate = "match" }),
    C.time(),
    -- A custom component uses the same sizing and highlight machinery.
    C.text({
      get = function(item) return item.cached and "cached" or nil end,
      searchable = false,
      hl = "Comment",
    }),
  },
  on_choice = function(item) print(item.file) end,
})
```

| Component | Default input | Default style | Searchable |
| --- | --- | --- | --- |
| `C.text()` | `item.text`, or a scalar item | `SelectionToolsText` (normal foreground) | Yes |
| `C.path()` | `item.file` | `SelectionToolsPath` → `Directory` | Yes |
| `C.position()` | `item.pos = { row, zero_based_column }` | `SelectionToolsPosition` → `Comment` | Yes |
| `C.time()` | `item.timestamp` (Unix seconds or a preformatted string) | `SelectionToolsTime` → `Number` | No |
| `C.icon()` | Existing file/directory icon provider | Provider's highlight group | No |

`field` maps a component to another item field; `get(item, original_index)` takes
precedence when supplied. Nil and empty strings omit the component and its gap.
`false` is displayed as text. Paths default to `path_format = ":~:."`; use `false`
to preserve an already formatted path. Positions display one-based columns. Times
default to `format = "%Y-%m-%d %H:%M:%S"` in the local timezone. Icon components
honor `item_icons`, `format_icon`, and the shared icon mode; their values cannot
be overridden with `field`/`get`, and they never participate in matching.

Options resolve from built-in defaults, then `component_defaults[kind]` (global
and per picker), then the descriptor. Use `hl = false` to inherit the row's color.
Public highlight groups remain theme/user-owned and can be overridden normally.

Columns measure only visible candidates, using terminal display cells. Options:

- `width`: preferred width; `max_width`: cap; `min_width`: minimum before hiding.
- `grow`: share of spare space (default 0, or 1 for paths).
- `align`: `"left"` or `"right"` within the column.
- `truncate`: `"right"`, `"left"` (paths), or `"match"` to retain query context.
- `priority`: lower values shrink/hide first: icon 10, time 40, position 50,
  path 80, text 100. Equal priorities prefer retaining earlier columns.

Nonempty columns have one cell between them. Widths are preferred allocations;
lower-priority columns shrink to their minima, then disappear if necessary.
Minima are bounded by the available content. Truncation preserves composed UTF-8
characters, and hidden/truncated content remains searchable.

Search uses the complete values of `searchable = true` components, in descriptor
order, joined with a single space. Controls are escaped independently of display
padding and clipping.
Changing width, styles, icons, or selection marks never changes the search text.
Query highlights map back to visible component fragments. Override with
`match_text(item, original_index)` to search aliases or hidden metadata; with
this override there is no inferred query-to-display mapping, so automatic query
highlights are omitted. Component-local highlights remain available.

Custom `highlights(item, original_index)` returns ranges such as
`{ { 0, 4, hl = "Function", priority = 100 } }`. Offsets are zero-based,
end-exclusive bytes in that component's formatted value **before** control
escaping. The renderer handles clipping, Unicode, and preceding columns.
Legacy `highlight_item` instead addresses the complete joined search text.
With `syntax.enabled = true`, an unmodified `C.text({ field = "code" })` can
receive file-context Tree-sitter colors from `item.file`, `item.pos`, and
`item.code`, including when the code component is display-only.

Searchable getters run once when candidates enter. Display-only getters,
highlighters, icon providers and width measurement run only for visible entries;
values/highlights are cached until candidates are replaced. Getters should be
pure and synchronous: fetch filesystem/network data in the source, and pass it
as fields. Use `set_items()` to publish changed values. Resizing reuses values;
icon-mode and display-width changes refresh layout without re-running getters.

Composed row and match-range caches retain only the visible candidates. Moving
the selection within a ready viewport preserves list text, syntax and match
highlights while updating the selection, count, preview and `on_change` callback.
Scrolling, changed results/layout/icons, and refreshed source syntax still
publish complete frames. Consecutive query hits share a highlight range;
unmatched gaps in fuzzy results retain their original styling.

`components` takes precedence over `format_item` and `result_layout`. Lists replace
earlier component lists, including when empty; `components = false` selects the
legacy formatter. Files, buffers and recent files use icon/path components by
default; supplying `format_item` to those built-in pickers retains its legacy
behavior. Grep and undo keep their specialized layouts unless components are
explicitly provided.

### Registering sources

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
-- Also available through :SelectionTools tasks
```

A source can be a configuration table or a function that receives call options and returns a configuration table. Options passed to `pick(name, opts)` override source defaults.

### Asynchronous or dynamic search

```lua
local picker = require("selection_tools").open({
  prompt = "Remote results",
  live = true, -- Run finder again on each query change; by default it runs once
  match = false, -- Disable local fuzzy matching when the source filters and ranks results
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

`ctx.set_items()` replaces candidates, `ctx.done()` finishes loading, and `ctx.fail(message)` displays an error. These methods can be called directly from asynchronous callbacks. Closing the window or updating a live query runs the finder's returned cancellation function and discards old results. Restarting a live source keeps the old list until new results are ready, with confirmation paused to avoid selecting results from an old query.

Sources can return `{{start_byte, end_byte}, ...}` from `highlight_item(item, original_index)` to highlight ranges of formatted items with `SelectionToolsMatch`. Ranges use zero-based, end-exclusive byte offsets into the original string returned by `format_item`; the renderer handles display transformations for icons, selection marks, tabs, and other control characters. The callback runs only for visible candidates, with results cached until candidates are replaced. Grep uses ripgrep's actual match ranges without reinterpreting regexes or applying fuzzy matching.

`match_priority(item, original_index)` can return a finite numeric priority for
stable groups: lower values appear first, with matcher relevance retained within
each group. Original item indices and query highlights are preserved.

The returned picker provides `set_query(query)`, `set_items(items)`, `move(delta)`, `current()`, `confirm()`, and `close()`. `current()` returns the current item and its original index; `close()` cancels.

Sources can extend previews: `preview = { enabled = true }` enables them, and `previewer(ctx)` receives `item`, `index`, `buf`, `win`, `is_cancelled()`, and `set_lines(lines, filetype, title, position)`. `set_lines` supports asynchronous callbacks; the previewer may return a cancellation function. Define additional actions with `actions = { name = function(picker) ... end }` and bind them through `keys.name`.

Open a temporary child with `nested = true` while a picker owns the focused
window. The parent stays alive with its original buffers, query, selection,
marks and preview. Closing the child restores the parent window and Insert
position. Finder deliveries wait until the child closes. Children do not replace
resume history. Ordinary opens still replace the entire active picker chain;
closing a parent, disposing the plugin or clicking an editor outside the chain
also closes its children. `selection.current(win)` returns the live owner of a
window; omit `win` for the focused window. `picker:owns_window(win)` checks its
own input, list, preview and details windows.

Picker mappings expose readable `desc` fields. Custom actions can set
`action_descriptions = { name = "Description" }` alongside `actions` and `keys`.

See `:help selection-tools` for configuration, key bindings, and the full API.

## Validation

```sh
stylua --check lua plugin tests
nvim --headless -u NONE -n -i NONE -l tests/run.lua
nvim --headless -u NONE -n -i NONE -l tests/sources.lua
nvim --headless -u NONE -n -i NONE -l tests/file_windows.lua
nvim --headless -u NONE -n -i NONE -l tests/lazy.lua
nvim --headless -u NONE -n -i NONE -l tests/item_icons.lua
nvim --headless -u NONE -n -i NONE -l tests/components.lua
nvim --headless -u NONE -n -i NONE -l tests/rendering.lua
nvim --headless -u NONE -n -i NONE -l tests/syntax.lua
nvim --headless -u NONE -n -i NONE -l tests/grep_columns.lua
nvim --headless -u NONE -n -i NONE -l tests/content_columns.lua
nvim --headless -u NONE -n -i NONE -l tests/workflows.lua
nvim --headless -u NONE -n -i NONE -l tests/borders.lua
nvim --headless -u NONE -n -i NONE -l tests/labels.lua
nvim --headless -u NONE -n -i NONE -l tests/streaming.lua
nvim --headless -u NONE -n -i NONE -l tests/preview_providers.lua
nvim --headless -u NONE -n -i NONE -l tests/preview_scroll.lua
nvim --headless -u NONE -n -i NONE -l tests/transactions.lua
nvim --headless -u NONE -n -i NONE -l tests/nested.lua
nvim --headless -u NONE -n -i NONE -l tests/on_change.lua
nvim --headless -u NONE -n -i NONE -l tests/undo_tree.lua
# Optional: sibling git-tools.nvim (or GIT_TOOLS_DIR) and delta
nvim --headless -u NONE -n -i NONE -l tests/undo.lua
# Optional: real image-tools API and media/cache integration; tests simulate Kitty responses
IMAGE_TOOLS_ROOT=/path/to/image-tools.nvim nvim --headless -u NONE -n -i NONE -l tests/image_tools.lua
python3 tests/tui.py
```

`nvim --headless -u NONE -n -i NONE -l tests/components_bench.lua` compares the
legacy and component paths with 50,000 candidates (five samples, medians). It
reports opening/first-query/movement latency (in-view and scrolling), retained Lua heap, and lazy
decoration calls; set `SELECTION_TOOLS_BENCH_ITEMS` to change the candidate count.

Tests cover object/index preservation, cancellation and lifecycle, stale asynchronous results, file search backends, confirmation behavior of built-in sources, and real terminal input. Icon catalog downloads, caching, failures, and cancellation use offline mocks. When skim is installed, tests also exercise real skim and terminal typing, previews, and multiple selection with 60000 candidates; otherwise these external integration tests are skipped. Terminal tests use Python's standard-library PTY support on macOS/Linux.

## Built-in sources

- `grep({ cwd, query, regex = false, hidden, ignored, limit = 10000 })`: live full-text search, using literal strings and ripgrep smart case by default; `regex = true` enables regular expressions. Results carry line/column positions and jump there on confirmation. The list highlights every actual match on each line for both literal and regex searches. Empty queries do not scan directories.

- `projects({ projects, dev, recent = true, max_depth = 2, open_files = true })`: combines the current project, project roots from recent files, explicit directories, and development-directory scans. Confirmation changes the working directory and opens file search; `open_files = false` only changes directories.

- `recent({ cwd, buffers = true })`: merges listed file buffers and `v:oldfiles` by recency, skipping deleted files and deduplicating path aliases. An explicit `cwd` restricts the directory.

- `resume()` / `:SelectionTools resume`: restores the last picker's source, query, current selection, marks, and preview scroll position. Static lists retain their original objects; live or unfinished searches reload. Use `resume = false` to disable recording for a picker.

- `todo_comments({ cwd, keywords })`: scans `KEYWORD:` TODO markers, including NOTE by default. Reads configured keywords and aliases from todo-comments when available, or accepts an explicit keyword list. Standalone use does not require the todo-comments plugin.

- `registers({ registers, register = "+" })`: searches nonempty registers and previews multiline content. Confirmation copies content and register type to the target register. Avoids proactively reading the OSC 52 clipboard by default.

- `jumps()`: browses the current window's native jump list. Confirmation moves forward/backward by native jump-list index, preserving subsequent jump behavior.

- `marks()`: combines local marks from the current buffer with global marks, displays and previews exact locations, and jumps on confirmation.

- `undo()`: browses a compact undo graph, grouping sibling branches with newer descendants before their shared ancestors. `●` marks a version, `◆` the current version, and connecting lines show actual ancestry. Adjacent forks leave the parent's row with a rounded bend toward the child. Time is the primary highlighted column; muted sequence numbers align at the right edge, including after resizing. `saved` marks the last write. Search keeps matching versions and their dimmed ancestors (`context`); `#42` selects an exact sequence. The default preview compares the real parent → selected version, showing that undo block's own change. **F4** toggles comparison with the current snapshot captured on open; `compare = "current"` selects that mode initially (`"parent"` is the default). The divider identifies the baseline, and switching preserves the query and selection. Resume preserves the mode. Initial states and pruned parents show snapshots with an explanatory title. Historical content is read in an isolated clone, using git-tools.nvim's diff generation and native rendering. Native colors follow theme-tools when loaded, and the repeated file heading is omitted while hunk locations remain visible. `native` customizes the renderer. `wrap = true/false` overrides the git-tools default. **Alt+Z** toggles wrapping from the input/list in Insert or Normal mode, including initial snapshots and no-change pages; the setting survives version changes and **F4** comparison switches. Side-by-side diffs wrap each column independently. `backend = "delta"` enables ANSI rendering; missing/failed delta falls back to native. `backend = "vim"` shows the raw patch. Without git-tools.nvim, previews full snapshots. Only confirmation changes the original buffer; stale content is rejected. Closing cleans up temporary undo files, clones, processes, and preview buffers.

- `search_history()`: restores the search register and runs the selected search in the original window.

- `command_history()`: selects command history in recency order and executes the chosen command in the original window.

- `qflist()`: selects Quickfix entries, previews files, and preserves native list indices. Rejects stale positions if the list changes.

- `loclist()`: reads the calling window's Location list and jumps in that window, rather than reading the picker window's list.

- `commands()`: searches built-in, global, and buffer-local commands. Fills the command line by default so arguments can be added; `execute=true` runs the command directly.

- `autocmds()`: searches events, groups, patterns, and descriptions, and previews full definitions. Confirmation locates the Lua definition or opens read-only details.

- `keymaps()`: searches global and buffer-local mappings across modes and previews definitions. Confirmation locates the definition without executing the mapping. Use keymap-tools.nvim for mode-aware keymap execution.

- `help()`: searches runtime help tags, previews their locations, and opens native help on confirmation. Tag files are read asynchronously and parsed in batches after the window appears. Cache invalidation follows tag-file metadata and runtime order.

- `man()`: indexes pages from local manpath directories, previews them through asynchronous `man` calls, and opens them with native `:Man` on confirmation. Use `paths` to specify directories.

- `spelling()`: replaces the word under the cursor in the original window, preserving other occurrences. Rejects stale replacements if the original text changes. Retains the compact spelling layout with input on top.

- `highlights()`: searches highlight groups and previews actual styles, links, and resolved color attributes. Confirmation closes the picker; `<C-y>` copies the name.

- `icons()`: searches Nerd Fonts, Emoji, optional devicons, and built-in symbols, then inserts the selection in the original buffer. Public glyph catalogs are downloaded asynchronously and cached on first use. `icon_sources={}` disables downloads; `icons` or `custom_sources` can supply local catalogs.

All sources are available through `pick(name, opts)`, the Lua function with the same name, or `:SelectionTools name`. Keymaps for live full-text search can use `grep({ regex = true })` to retain the original Snacks regex search behavior.

Icon catalogs come from [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) and [unicode-emoji-json](https://github.com/muan/unicode-emoji-json). The initial download requires curl; local symbols and devicons remain available if it fails. `custom_sources = { name = "/path/icons.json" }` accepts `[{"icon":"λ","name":"lambda","category":"math"}]` or `[["λ","lambda"]]`. Remote catalogs are cached under `stdpath("cache")/selection-tools/icons/`.

Highlight attributes, keymap/autocommand definitions, and user-command details are generated only when the current item is previewed. Keymap definition lookup reuses a script index within each picker and refreshes it for a new picker.

Help, highlights, keymaps, autocommands, commands, and projects show the window before preparing candidates in batches. Input and cancellation remain available during loading, and the current query is applied when candidates are ready. Project scans reuse both found and missing project roots within a load. Lazy-loading tests verify lightweight entry-point registration at startup, plus input, cancellation, file-handle cleanup, and cache reuse during loading in a real terminal.

When theme-tools.nvim is active, picker borders, selections, matches, marks and
secondary text follow its shared semantic palette, including theme previews and
restoration. The integration is optional, does not load theme-tools itself, and
keeps standard Neovim highlight defaults when it is unavailable.

Public highlight definitions from your colorscheme or user overrides take precedence
over shared palette updates. Private default targets are refreshed on theme changes.

Run `nvim --headless -u NONE -l tests/theme_ownership.lua` for explicit override and rollback checks.
Run `nvim --headless -u NONE -l tests/theme.lua` with the real sibling theme-tools
checkout (or set `THEME_TOOLS_DIR`) to validate this integration.

## Shared icon display

When theme-tools.nvim is configured, icons follow its shared icon API and
`:ThemeToolsIcons` selection (mini.icons, nvim-web-devicons, ASCII, or hidden).
Open views refresh when the display changes. Provider installation and updates
belong to theme-tools; no extra icon dependency is needed for this integration.
Without theme-tools, existing standalone defaults remain available.
Local icon-disable options still apply. Configure shared overrides through
`require("theme_tools").setup({ icons = { overrides = { ... } } })`.

## Command ownership

Commands belong to the plugin; choose global entry keys and short aliases in
your configuration. Registration reports same-name conflicts without replacing
user commands. Reconfiguration refreshes only commands still owned by this
plugin, and cleanup preserves subsequent user replacements.

## Setup contract

`setup(nil)` uses defaults. Configuration must be a table; caller-owned tables
are copied before use. Invalid configuration types do not replace live handlers
or commands. Repeating setup must not accumulate automatic registrations.

`setup(opts)` validates layout and adapter options before changing the current
configuration or `vim.ui.select`. `dispose()` closes the owned picker, cancels
its asynchronous work, releases theme subscriptions and restores `vim.ui.select`
only while still owned. It resets setup options, preserves registered custom
sources, and is safe to repeat; call setup to install the adapter again.

User-command metadata and highlight-definition tables use Lua syntax in previews. Expanded item details retain the item filetype and syntax, matching the preview.
