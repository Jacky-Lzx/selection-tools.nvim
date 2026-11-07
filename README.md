# selection-tools.nvim

Reusable searchable pickers and built-in file, buffer and text sources.

## Features

- Search files, buffers, text and other built-in sources.
- Preview results, mark items and export to quickfix or location lists.
- Build custom sources and nested pickers with explicit lifecycle ownership.

## Requirements

Neovim **0.10+**. File search needs `fd` or `rg`; grep needs `rg`. Ordinary list selection has no external dependency. Icons and skim matching are optional.

## Installation

With lazy.nvim:

```lua
{
  "Jacky-Lzx/selection-tools.nvim",
  main = "selection_tools",
  opts = {},
}
```

Or put this repository and its required dependencies on `runtimepath`, then call:

```lua
require("selection_tools").setup({})
```

## Usage

```vim
:SelectionTools files
:SelectionTools buffers
```

## Documentation

- [Complete reference](doc/selection-tools.txt) — `:help selection-tools`.
- [Workflow and integration guide](doc/guide.md).

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.

[License](LICENSE).
