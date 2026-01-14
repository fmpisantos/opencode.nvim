# opencode.nvim

A Neovim plugin that integrates the [opencode](https://opencode.ai) CLI tool, allowing you to interact with AI coding assistants directly from your editor.

## Features

- **Prompt Window**: Open a floating window to send prompts to the AI assistant
- **Code Selection**: Include visual selections in your prompts (automatically wrapped in markdown code fences)
- **Agent Modes**: Switch between `build` mode (code generation) and `plan` mode (task planning) using `#plan` in your prompt
- **Model Selection**: Choose AI models via Telescope picker, with persistence across sessions
- **Code Review**: Review git changes with AI using various revision formats (commits, branches, tags)
- **Streaming Responses**: Real-time response display in a vertical split with markdown highlighting

## Requirements

- Neovim 0.9+
- [opencode](https://opencode.ai) CLI installed and available in PATH
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (for model selection)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "fmpisantos/opencode.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("opencode")
  end,
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "fmpisantos/opencode.nvim",
  requires = { "nvim-telescope/telescope.nvim" },
  config = function()
    require("opencode")
  end,
}
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:OpenCode` | Open the prompt floating window |
| `:OpenCodeWSelection` | Open prompt with current visual selection |
| `:OpenCodeModel` | Open Telescope picker to select AI model |
| `:OpenCodeReview` | Open review prompt for git revisions |

### Default Keymaps

| Mode | Keymap | Action |
|------|--------|--------|
| Normal | `<leader>oc` | Open prompt window |
| Visual | `<leader>oc` | Open prompt with selection |

### Prompt Window Keybindings

- `:w` or `:wq` - Submit the prompt
- `q` or `<Esc>` - Close without submitting

### Special Markers

Use these markers in your prompts for additional functionality:

- `#plan` - Switch to plan mode for task planning
- `#buffer` or `#buf` - Reference the current file

### Code Review

The `:OpenCodeReview` command accepts various git revision formats:

- `HEAD~3` - Last 3 commits
- `abc123` - Specific commit hash
- `main..feature` - Branch comparison
- `v1.0.0` - Tag reference

## How It Works

1. On first use, the plugin automatically initializes opencode by running `opencode agent create` if `AGENTS.md` doesn't exist in your project
2. Prompts are sent to the opencode CLI with the selected model and agent mode
3. Responses are streamed in real-time to a vertical split buffer with markdown syntax highlighting
4. Model selection is persisted to `~/.local/share/nvim/opencode/config.json`

## License

MIT
