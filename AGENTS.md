# AGENTS.md - opencode.nvim Development Guide

This document provides essential information for AI coding agents working on the opencode.nvim Neovim plugin.

## Project Overview

opencode.nvim is a Neovim plugin that integrates the [opencode](https://opencode.ai) CLI tool, allowing users to interact with AI coding assistants directly from their editor. The plugin is written in Lua and follows Neovim plugin conventions.

## Repository Structure

```
opencode.nvim/
├── README.md                           # User-facing documentation
├── ftdetect/
│   └── opencode.lua                    # Filetype detection
├── ftplugin/
│   └── opencode.lua                    # Filetype-specific features
└── lua/
    └── opencode/
        └── init.lua                    # Main plugin implementation
```

**Important**: `ftdetect/` and `ftplugin/` MUST be at the root level, not inside `lua/`. Neovim automatically loads these directories from the plugin root.

## Build, Test, and Lint Commands

### Testing
- **No formal test suite exists yet** - this is an area for potential improvement
- Manual testing: Install in Neovim and use `:OpenCode`, `:OpenCodeModel`, `:OpenCodeReview` commands
- Test with visual selections: Select text in visual mode and use `<leader>oc`

### Linting
- No configured linters (e.g., luacheck, stylua) - follows manual code style
- When adding linting, consider: `.luacheckrc` for luacheck or `stylua.toml` for stylua

### Running in Neovim
```vim
" Source the plugin during development
:luafile lua/opencode/init.lua

" Reload the plugin
:lua package.loaded['opencode'] = nil
:lua require('opencode')
```

## Code Style Guidelines

### File Organization
- Use clear section separators with comment blocks:
```lua
-- =============================================================================
-- Section Name
-- =============================================================================
```
- Group related functions together in logical sections
- Order sections: Constants → State → Helper Functions → Main Logic → Commands

### Imports and Dependencies
- External dependencies at the top of functions where needed:
```lua
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
```
- Core Neovim APIs accessed via `vim.*` global
- No external package manager or dependency file (Neovim plugin ecosystem)

### Naming Conventions
- **Module tables**: Single uppercase letter `M` for main module
- **Local functions**: `snake_case` for private functions
- **Module functions**: `M.PascalCase` for public API functions
- **Constants**: `UPPER_SNAKE_CASE` with local scope
- **Variables**: `snake_case` for all variables
- **Classes/Objects**: `PascalCase` for class-like tables (e.g., `Spinner`)

### Functions and Documentation
- Use LuaLS/EmmyLua annotations for type hints:
```lua
---@param buf number Buffer handle
---@param prefix string Loading message prefix
---@return Spinner
function Spinner.new(buf, prefix)
```
- Document complex functions with `---` comments
- Keep functions focused and single-purpose
- Use descriptive parameter names

### Types and Type Annotations
- Prefer explicit type annotations for public APIs
- Use `---@class` for OOP-style tables:
```lua
---@class Spinner
---@field private buf number
---@field private is_running boolean
```
- Use `---@param` and `---@return` for function signatures
- Optional parameters marked with `?`: `---@param is_running? boolean`

### Error Handling
- Use `pcall` for operations that may fail:
```lua
local ok, data = pcall(vim.json.decode, content)
if ok and data then
    -- Process data
end
```
- Schedule UI updates with `vim.schedule()` for async callbacks
- Validate buffer/window handles before operations:
```lua
if not vim.api.nvim_buf_is_valid(buf) then
    return
end
```
- Provide user feedback via `vim.notify()` for non-critical errors

### Lua Specific Patterns
- Use `vim.fn` for Vimscript functions: `vim.fn.getcwd()`, `vim.fn.filereadable()`
- Use `vim.api` for Neovim API calls: `vim.api.nvim_create_buf()`
- Use `vim.bo[buf]` and `vim.b[buf]` for buffer-local options/variables
- Prefer `vim.system()` for async command execution over `vim.fn.system()`
- Use `vim.iter()` for functional iteration on tables (Neovim 0.10+)

### Async Patterns
- Use `vim.system()` for non-blocking external commands:
```lua
vim.system({ "opencode", "models" }, { cwd = nvim_cwd }, function(result)
    vim.schedule(function()
        -- Process result in main thread
    end)
end)
```
- Always wrap UI updates in `vim.schedule()` when in async context
- Use timers via `vim.fn.timer_start()` for periodic updates

### String Handling
- Use `string.gsub()` for pattern replacements
- Use `vim.split()` for splitting strings: `vim.split(text, "\n", { plain = true })`
- Use `table.concat()` for joining arrays into strings
- Use `vim.trim()` for whitespace trimming

### Buffer and Window Management
- Create scratch buffers with `vim.api.nvim_create_buf(false, true)`
- Set buffer options via `vim.bo[buf]` instead of `vim.api.nvim_buf_set_option()`
- Use `buftype = "nofile"` for temporary buffers
- Use `buftype = "acwrite"` for prompt buffers with custom save behavior
- Always validate handles before operations

### Configuration and State
- Store user configuration in `vim.fn.stdpath("data")` for persistence
- Use JSON for config files: `vim.json.encode()` / `vim.json.decode()`
- Module-level state in local variables at top of file
- Buffer-local state via `vim.b[buf].variable_name`

### User Commands and Keymaps
- Define user commands with `vim.api.nvim_create_user_command()`
- Use `<Cmd>...<CR>` for keymaps to avoid mode changes:
```lua
vim.keymap.set("n", "<leader>oc", "<Cmd>OpenCode<CR>", { noremap = true, silent = true })
```
- Provide buffer-local keymaps via `{ buffer = buf }` option
- Use descriptive command names in PascalCase: `:OpenCode`, `:OpenCodeModel`

### Git Commit Message Style
- Use conventional commit format: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`
- Keep first line concise and descriptive
- Example: `feat: Working solution`, `feat: Initial commit`

## Common Pitfalls

1. **Async UI updates**: Always wrap in `vim.schedule()` when updating UI from callbacks
2. **Handle validation**: Check if buffers/windows are valid before operating on them
3. **Mode handling**: Use `vim.api.nvim_feedkeys()` with correct flags for mode transitions
4. **External dependencies**: Plugin requires `telescope.nvim` and `opencode` CLI in PATH
5. **File paths**: Use `vim.fn.filereadable()` to check existence before reading files

## External Dependencies

- **Neovim**: Version 0.9+ required (consider 0.10+ features like `vim.iter`)
- **telescope.nvim**: Required for model selection and file finding
- **opencode CLI**: Must be installed and available in PATH

## Plugin Initialization

The plugin automatically initializes itself when required. It:
1. Loads user configuration from `~/.local/share/nvim/opencode/config.json`
2. Creates user commands: `:OpenCode`, `:OpenCodeWSelection`, `:OpenCodeModel`, `:OpenCodeReview`
3. Sets up default keymaps: `<leader>oc` in normal and visual modes
4. Auto-creates `AGENTS.md` in projects via `opencode agent create` on first use

## Key Features to Preserve

- **Floating prompt window** with dynamic title showing mode and model
- **Visual selection support** with automatic code fence wrapping
- **Streaming responses** in vertical split with markdown highlighting
- **Draft persistence** when closing prompt window without submitting
- **Model selection** with persistent config across sessions
- **Git review** with flexible revision format support
- **File references** via `@` trigger in prompt window
- **Buffer shortcuts**: `#buffer` / `#buf` expand to current file path
- **Agent modes**: `build` (default) and `plan` (triggered by `#plan` in prompt)

## Contributing Guidelines

When making changes:
- Follow the existing code style and section organization
- Add LuaLS annotations for new public functions
- Test manually with different Neovim versions if possible
- Update README.md for user-facing changes
- Consider backward compatibility with Neovim 0.9+
- Validate buffer/window handles before operations
- Use `vim.schedule()` for all async UI updates
