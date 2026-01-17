# AGENTS.md - opencode.nvim Development Guide

## Project Overview

opencode.nvim is a Neovim plugin integrating the [opencode](https://opencode.ai) CLI tool for AI-assisted coding. Written in Lua, it follows Neovim plugin conventions.

## Repository Structure

```
opencode.nvim/
├── ftdetect/opencode.lua     # Filetype detection
├── ftplugin/opencode.lua     # Filetype-specific features
└── lua/opencode/
    ├── init.lua              # Main entry point, prompt/review windows
    ├── config.lua            # Configuration, state, constants
    ├── commands.lua          # User commands and keymaps
    ├── ui.lua                # UI components (Spinner, windows, buffers)
    ├── utils.lua             # Shared utilities
    ├── session.lua           # Session management
    ├── server.lua            # Server management (agentic mode)
    ├── runner.lua            # Command execution
    ├── requests.lua          # Request tracking
    └── response.lua          # Response handling
```

**Important**: `ftdetect/` and `ftplugin/` MUST be at the root level for Neovim to auto-load them.

## Build, Test, and Lint Commands

### Testing
- **No formal test suite exists** - manual testing required
- Test in Neovim: `:OpenCode`, `:OpenCodeModel`, `:OpenCodeReview`
- Test visual selection: Select text, then `<leader>oc`

### Development Workflow
```vim
" Reload plugin during development
:lua package.loaded['opencode'] = nil
:lua package.loaded['opencode.config'] = nil
:lua require('opencode').setup()
```

### Linting
- No configured linters - follows manual code style
- Consider: `.luacheckrc` for luacheck or `stylua.toml` for stylua

## Code Style Guidelines

### File Organization
- Section separators: `-- =========...`
- Order: Constants -> State -> Helper Functions -> Main Logic -> Setup

### Naming Conventions
| Type | Convention | Example |
|------|------------|---------|
| Module table | Single `M` | `local M = {}` |
| Local functions | `snake_case` | `get_source_file` |
| Public functions | `M.PascalCase` | `M.OpenCode()` |
| Constants | `UPPER_SNAKE_CASE` | `SPINNER_FRAMES` |
| Classes | `PascalCase` | `Spinner` |

### Imports
```lua
-- External deps inside functions where needed
local pickers = require("telescope.pickers")

-- Module imports at top of file
local config = require("opencode.config")
```

### Type Annotations (LuaLS/EmmyLua)
```lua
---@class OpenCodeState
---@field selected_model string|nil
---@field response_buf number|nil

---@param buf number Buffer handle
---@param prefix string Loading message
---@return Spinner
function Spinner.new(buf, prefix)
```

### Error Handling
```lua
-- Use pcall for fallible operations
local ok, data = pcall(vim.json.decode, content)
if ok and data then
    -- process
end

-- Validate handles before use
if not vim.api.nvim_buf_is_valid(buf) then return end

-- User feedback via vim.notify()
vim.notify("Error message", vim.log.levels.ERROR)
```

### Async Patterns
```lua
-- Use vim.system() for non-blocking commands
vim.system({ "opencode", "models" }, { text = true }, function(result)
    vim.schedule(function()
        -- UI updates MUST be in vim.schedule()
    end)
end)

-- Timers for periodic updates
vim.fn.timer_start(interval_ms, callback)
```

### Buffer/Window Management
```lua
-- Create scratch buffers
local buf = vim.api.nvim_create_buf(false, true)

-- Set options via vim.bo/vim.wo (not nvim_buf_set_option)
vim.bo[buf].buftype = "nofile"
vim.bo[buf].filetype = "markdown"

-- Buffer-local state
vim.b[buf].opencode_session_id = session_id
```

### Strings and Tables
```lua
vim.split(text, "\n", { plain = true })  -- Split strings
table.concat(lines, "\n")                 -- Join arrays
vim.trim(str)                             -- Trim whitespace
vim.iter(table):filter(fn):totable()      -- Functional iteration (0.10+)
```

### Commands and Keymaps
```lua
vim.api.nvim_create_user_command("OpenCode", function() ... end, { nargs = 0 })
vim.keymap.set("n", "<leader>oc", "<Cmd>OpenCode<CR>", { buffer = buf, silent = true })
```

## Key Patterns in This Codebase

### State Management
- Global state in `config.state` table
- Per-buffer state via `vim.b[buf].variable`
- Persistent config in `~/.local/share/nvim/opencode/`

### Window Title Updates
```lua
-- Only update floating windows (check relative field)
local win_config = vim.api.nvim_win_get_config(win)
if win_config.relative and win_config.relative ~= "" then
    vim.api.nvim_win_set_config(win, { title = new_title })
end
```

### Autocmd Groups
```lua
local augroup = vim.api.nvim_create_augroup("OpenCodePrompt_" .. buf, { clear = true })
vim.api.nvim_create_autocmd("TextChanged", { group = augroup, buffer = buf, callback = fn })
```

## External Dependencies

- **Neovim**: 0.9+ required (0.10+ recommended for `vim.iter`)
- **telescope.nvim**: Required for model selection and file picking
- **opencode CLI**: Must be in PATH

## Common Pitfalls

1. **Async UI updates**: Always wrap in `vim.schedule()` from callbacks
2. **Handle validation**: Check buffer/window validity before operations
3. **Buffer naming**: Use URI scheme (`opencode://prompt`) to avoid file path conflicts
4. **Mode transitions**: Use `vim.api.nvim_feedkeys()` with correct flags

## Git Commit Style

```
feat: Add new feature
fix: Fix bug description
refactor: Code restructuring
docs: Documentation changes
```

## Contributing Checklist

- [ ] Follow existing code style and section organization
- [ ] Add LuaLS annotations for public functions
- [ ] Validate buffer/window handles before operations
- [ ] Use `vim.schedule()` for async UI updates
- [ ] Test manually with Neovim 0.9+ and 0.10+
- [ ] Update README.md for user-facing changes
