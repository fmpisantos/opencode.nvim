# AGENTS.md - opencode.nvim Development Guide

## Project Overview

opencode.nvim is a Neovim plugin integrating the [opencode](https://opencode.ai) CLI tool for AI-assisted coding. Written in Lua, it follows Neovim plugin conventions.

## Repository Structure

```
opencode.nvim/
├── ftdetect/opencode.lua     # Filetype detection (must be at root)
├── ftplugin/opencode.lua     # Filetype-specific settings
└── lua/opencode/
    ├── init.lua              # Main entry, prompt/review windows, setup()
    ├── config.lua            # Configuration, state, constants, paths
    ├── commands.lua          # User commands (:OpenCode, :OCModel, etc.)
    ├── ui.lua                # Spinner class, floating windows, response buffer
    ├── utils.lua             # File utilities, string parsing, command building
    ├── session.lua           # Session persistence and management
    ├── server.lua            # Server lifecycle (agentic mode)
    ├── runner.lua            # Command execution via vim.system()
    ├── requests.lua          # Active request tracking and cancellation
    └── response.lua          # Response parsing and display
```

## Build, Test, and Lint Commands

### Testing (Manual)
No formal test suite exists. Test manually in Neovim:
```vim
:OpenCode              " Open prompt window
:OpenCodeModel         " Select AI model
:OpenCodeReview        " Git review
:OCMode agentic        " Switch modes
```

### Development Reload
```vim
:lua package.loaded['opencode'] = nil
:lua package.loaded['opencode.config'] = nil
:lua require('opencode').setup()
```

### Linting
No configured linters. Follow existing code style manually.

## Code Style Guidelines

### File Organization
- Section separators: `-- =========...` (80+ chars)
- Order: Constants -> State -> Helper Functions -> Main Logic -> Setup/Return

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
-- Internal modules at top of file
local config = require("opencode.config")
local utils = require("opencode.utils")

-- External deps inside functions (lazy loading)
local function some_function()
    local pickers = require("telescope.pickers")
end
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
-- Non-blocking commands with vim.system()
vim.system({ "opencode", "models" }, { text = true }, function(result)
    vim.schedule(function()
        -- UI updates MUST be wrapped in vim.schedule()
    end)
end)

-- Timers for periodic updates
vim.fn.timer_start(interval_ms, callback)
```

### Buffer/Window Management
```lua
-- Create scratch buffers
local buf = vim.api.nvim_create_buf(false, true)

-- Set options via vim.bo/vim.wo (NOT nvim_buf_set_option)
vim.bo[buf].buftype = "nofile"
vim.bo[buf].filetype = "markdown"

-- Buffer-local state
vim.b[buf].opencode_session_id = session_id

-- URI scheme for buffer names (avoids file path conflicts)
vim.api.nvim_buf_set_name(buf, "opencode://prompt")
```

### Commands and Keymaps
```lua
vim.api.nvim_create_user_command("OpenCode", function() ... end, { nargs = 0 })
vim.keymap.set("n", "<leader>oc", "<Cmd>OpenCode<CR>", { buffer = buf, silent = true })
```

## Key Patterns

### State Management
- Global state: `config.state` table (selected_model, response_buf, servers, etc.)
- Per-buffer state: `vim.b[buf].variable`
- Persistent config: `~/.local/share/nvim/opencode/config.json`

### Window Title Updates (Floating Windows Only)
```lua
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

- **Neovim**: 0.9+ required (0.10+ for `vim.iter`)
- **telescope.nvim**: Required for model/file selection
- **opencode CLI**: Must be in PATH

## Common Pitfalls

1. **Async UI updates**: Always wrap in `vim.schedule()` from callbacks
2. **Handle validation**: Check buffer/window validity before operations
3. **Buffer naming**: Use URI scheme (`opencode://prompt`) to avoid conflicts
4. **Mode transitions**: Use `vim.api.nvim_feedkeys()` with correct flags
5. **ftdetect/ftplugin**: Must remain at repository root for Neovim auto-loading

## Git Commit Style

```
feat: Add new feature
fix: Fix bug description
refactor: Code restructuring
docs: Documentation changes
```

## Contributing Checklist

- [ ] Follow existing code style and section separators
- [ ] Add LuaLS annotations for public functions
- [ ] Validate buffer/window handles before operations
- [ ] Use `vim.schedule()` for async UI updates
- [ ] Test manually with Neovim 0.9+ and 0.10+
- [ ] Update README.md for user-facing changes
