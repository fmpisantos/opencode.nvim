# opencode.nvim

A Neovim plugin that integrates the [opencode](https://opencode.ai) CLI tool, allowing you to interact with AI coding assistants directly from your editor.

## ✨ Features

- **🪟 Floating Prompt Window**: Clean, centered floating window for sending prompts to AI assistants
- **📝 Visual Selection Support**: Include code selections in your prompts (automatically wrapped in markdown code fences)
- **🤖 Dual Execution Modes**: 
  - `quick` mode - Direct CLI calls for fast, simple queries (default)
  - `agentic` mode - Server-based execution for complex, multi-step tasks
- **🎯 Model Selection**: Choose from available AI models via Telescope picker with persistent preferences
- **🔍 Git Review Integration**: Review commits, branches, and diffs with AI assistance
- **⚡ Streaming Responses**: Real-time response display with markdown syntax highlighting
- **📋 Todo List Display**: View OpenCode's task planning and progress directly in the response buffer
- **📂 File References**: Use `@` trigger to quickly reference files in your prompts
- **💾 Draft Persistence**: Unsaved prompts are preserved when closing the prompt window
- **🔄 Session Management**: Continue previous conversations with `#session` markers

## 📋 Requirements

- Neovim 0.9+ (0.10+ recommended for best experience)
- [opencode](https://opencode.ai) CLI tool installed and available in PATH
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) - For model selection and file references

### Optional Dependencies

- [shared_buffer.nvim](https://github.com/fmpisantos/shared_buffer.nvim) - Enhanced state persistence with file watching. If not installed, the plugin falls back to direct file-based persistence.

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "fmpisantos/opencode.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-telescope/telescope-ui-select.nvim",
    "nvim-telescope/telescope-fzf-native.nvim",
    "nvim-lua/plenary.nvim",
    -- Optional: enhanced state persistence with file watching
    { "fmpisantos/shared_buffer.nvim", optional = true },
  },
  config = function()
    require("opencode").setup()
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "fmpisantos/opencode.nvim",
  requires = {
    "nvim-telescope/telescope.nvim",
    "nvim-telescope/telescope-ui-select.nvim",
    "nvim-telescope/telescope-fzf-native.nvim",
    "nvim-lua/plenary.nvim",
    -- Optional: enhanced state persistence with file watching
    { "fmpisantos/shared_buffer.nvim", opt = true },
  },
  config = function()
    require("opencode").setup()
  end,
}
```

### Using [pack.nvim](https://github.com/fmpisantos/pack.nvim)

```lua
return {
  src = "fmpisantos/opencode.nvim",
  deps = {
    "nvim-telescope/telescope.nvim",
    "nvim-telescope/telescope-ui-select.nvim",
    "nvim-telescope/telescope-fzf-native.nvim",
    "nvim-lua/plenary.nvim",
    -- Optional: enhanced state persistence with file watching
    "fmpisantos/shared_buffer.nvim",
  },
  setup = function()
    require("opencode").setup()
  end,
}
```

## ⚙️ Configuration

The plugin works out of the box with sensible defaults. Customize by passing options to `setup()`:

```lua
require("opencode").setup({
  -- Window dimensions
  prompt_window = {
    width = 60,   -- Width of the prompt floating window
    height = 10,  -- Height of the prompt floating window
  },
  review_window = {
    width = 60,   -- Width of the review floating window
    height = 8,   -- Height of the review floating window
  },
  -- Response buffer options
  response_buffer = {
    wrap = true,  -- Enable line wrapping in response buffer (default: true)
  },
  -- Timeout in milliseconds for opencode commands (default: 2 minutes)
  -- Set to -1 for unlimited timeout (no timeout)
  timeout_ms = 120000,
  -- Keymaps
  keymaps = {
    enable_default = true,            -- Set to false to disable default keymaps
    open_prompt = "<leader>oc",       -- Keymap to open prompt window
  },
})
```

### Custom Keymap Example

If you want to disable default keymaps and set your own:

```lua
require("opencode").setup({
  keymaps = {
    enable_default = false,  -- Disable default <leader>oc keymap
  },
})

-- Set your own keymaps
vim.keymap.set("n", "<leader>ai", "<Cmd>OpenCode<CR>", { desc = "Open OpenCode" })
vim.keymap.set("v", "<leader>ai", "<Cmd>OpenCodeWSelection<CR>", { desc = "OpenCode with selection" })
vim.keymap.set("n", "<leader>am", "<Cmd>OpenCodeModel<CR>", { desc = "Select AI model" })
vim.keymap.set("n", "<leader>ar", "<Cmd>OpenCodeReview<CR>", { desc = "Review git changes" })
vim.keymap.set("n", "<leader>as", "<Cmd>OpenCodeSessions<CR>", { desc = "Browse sessions" })
vim.keymap.set("n", "<leader>ax", "<Cmd>OpenCodeStop<CR>", { desc = "Stop active requests" })
vim.keymap.set("n", "<leader>at", "<Cmd>OpenCodeCLI<CR>", { desc = "Toggle response buffer" })
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `prompt_window.width` | number | `60` | Width of the prompt floating window |
| `prompt_window.height` | number | `10` | Height of the prompt floating window |
| `review_window.width` | number | `60` | Width of the review floating window |
| `review_window.height` | number | `8` | Height of the review floating window |
| `response_buffer.wrap` | boolean | `true` | Enable line wrapping in response buffer |
| `timeout_ms` | number | `120000` | Timeout in milliseconds for opencode commands (2 minutes default). Set to `-1` for unlimited timeout. |
| `keymaps.enable_default` | boolean | `true` | Enable default keymaps |
| `keymaps.open_prompt` | string | `<leader>oc` | Keymap to open prompt window |

## 🚀 Usage

### Commands (`:` Commands)

All commands have both a full name and a short abbreviation:

| Command | Abbreviation | Description |
|---------|-------------|-------------|
| `:OpenCode` | `:OC` | Open the prompt floating window |
| `:OpenCodeWSelection` | - | Open prompt with current visual selection |
| `:OpenCodeModel` | `:OCModel` | Open Telescope picker to select AI model |
| `:OpenCodeReview` | `:OCReview` | Open review prompt for git revisions |
| `:OpenCodeCLI` | `:OCCLI` | Toggle the response buffer visibility |
| `:OpenCodeSessions` | `:OCSessions` | Open session picker to view/manage saved sessions |
| `:OpenCodeInit` | `:OCInit` | Initialize opencode for the current project (creates AGENTS.md) |
| `:OpenCodeStop` | `:OCStop` | Stop all active AI requests |
| `:OpenCodeAttachWindow` | `:OCAttachWindow` | Attach the floating prompt to a regular split window |
| `:OpenCodeMode [mode]` | `:OCMode [mode]` | Toggle or set mode (`quick` or `agentic`). Omit argument to toggle. |
| `:OpenCodeServerStatus` | `:OCServerStatus` | Show the status of the opencode server (agentic mode) |
| `:OpenCodeServerStart` | `:OCServerStart` | Start the opencode server for agentic mode |
| `:OpenCodeServerStop` | `:OCServerStop` | Stop the opencode server |
| `:OpenCodeServerRestart` | `:OCServerRestart` | Restart the opencode server |

### Default Keymaps

| Mode | Keymap | Action |
|------|--------|--------|
| Normal | `<leader>oc` | Open prompt window |
| Visual | `<leader>oc` | Open prompt with selection |

**Note**: You can disable default keymaps by setting `keymaps.enable_default = false` in setup. All commands also have abbreviation versions (e.g., `:OC`, `:OCModel`, `:OCReview`) that can be used in custom keymaps.

### Prompt Window Keybindings

Inside the OpenCode prompt window:

| Key | Action |
|-----|--------|
| `:w` or `:wq` | Submit the prompt to AI |
| `q` or `<Esc>` | Close without submitting (saves draft) |
| `@` | Trigger Telescope file picker to insert file reference |
| `<C-x><C-e>` | Attach the floating prompt to a regular split window |

### Special Markers (`#` Commands)

Use these markers in your prompts for additional functionality:

| Marker | Description | Example |
|--------|-------------|---------|
| `#plan` | Switch to plan mode for task planning | `#plan How should I architect this feature?` |
| `#buffer` or `#buf` | Reference the current file (auto-expands to file path) | `Refactor #buffer to use async/await` |
| `#session` | Open session picker to continue a previous session | Type `#session` to select from saved sessions |
| `#session(<id>)` | Continue a specific session by ID | `#session(ses_abc123) Follow up on that...` |
| `#agentic` | Switch to agentic mode (uses server for requests) | `#agentic Implement this complex feature` |
| `#quick` | Switch to quick mode (direct CLI calls) | `#quick Just explain this code` |
| `@` | Opens Telescope file picker to reference any file | Type `@` then select file from picker |

### Code Review

The `:OpenCodeReview` command accepts various git revision formats:

| Format | Description | Example |
|--------|-------------|---------|
| `HEAD~N` | Last N commits | `HEAD~3` - Last 3 commits |
| `<hash>` | Specific commit | `abc123` - Review commit abc123 |
| `<ref>..<ref>` | Range comparison | `main..feature` - Compare branches |
| `<tag>` | Tag reference | `v1.0.0` - Review tag v1.0.0 |
| Empty | Default review | Leave empty for current changes |

### Usage Examples

**Basic prompt:**
```
# In normal mode, press <leader>oc
Write a function to validate email addresses
```

**With code selection:**
```lua
-- Select this code in visual mode, then press <leader>oc
function process_data(items)
  -- Your implementation
end
```
Then in the prompt window:
```
Optimize this function for large datasets
```

**Using plan mode:**
```
#plan Create a test suite for the authentication module
```

**Referencing current file:**
```
Add error handling to #buffer
```

**Referencing multiple files:**
```
Refactor @src/utils.lua and @src/helpers.lua to reduce duplication
```
*(Use `@` to trigger file picker for each file)*

**Continuing a session:**
```
#session
```
*(Opens session picker to select a previous conversation)*

**Switching to agentic mode for complex tasks:**
```
#agentic Implement a complete user authentication system with tests
```

**Git review:**
```vim
:OpenCodeReview
# In the review window, enter:
HEAD~5
```
The AI will review your last 5 commits and provide feedback.

**Stop an active request:**
```vim
:OCStop
```

## 🔀 Execution Modes

OpenCode supports two execution modes that determine how requests are processed:

### Quick Mode (Default)
- Direct CLI calls to the `opencode` command
- Best for simple queries, quick questions, and one-off tasks
- Lower latency for simple requests
- Each request is independent

### Agentic Mode
- Uses a persistent opencode server for request handling
- Best for complex, multi-step tasks that benefit from context
- Server starts automatically when needed (or manually with `:OCServerStart`)
- Maintains state across requests within the same server session

### Switching Modes

**Via Command:**
```vim
:OCMode quick      " Switch to quick mode
:OCMode agentic    " Switch to agentic mode
:OCMode            " Toggle between modes
```

**Via Prompt Marker:**
```
#agentic Implement this complex feature with tests
#quick Just explain what this function does
```

### Server Management (Agentic Mode)

When using agentic mode, you can manage the server:

| Command | Description |
|---------|-------------|
| `:OCServerStatus` | Check if server is running and get URL |
| `:OCServerStart` | Manually start the server |
| `:OCServerStop` | Stop the server |
| `:OCServerRestart` | Restart the server |

## 💾 Session Management

OpenCode provides comprehensive session management to maintain conversation context across multiple interactions:

### Session Persistence
- **Automatic Saving**: Each conversation is automatically saved to `/tmp/opencode-nvim-sessions/` using the opencode CLI session ID
- **Session Files**: Conversations are stored as markdown files with full query/response history
- **Response Buffer**: Active sessions display in a dedicated vertical split buffer with syntax highlighting

### Continuing Sessions

**Using the `#session` marker** in the prompt window:
1. Type `#session` (without parentheses) to open the session picker
2. Select a previous session to continue, or start a new one
3. The session ID is automatically inserted as `#session(<id>)`

**Using a specific session ID:**
```
#session(ses_abc123def456) How should we optimize this function further?
```

When continuing a session, the plugin:
1. Loads the previous conversation from the session file
2. Passes `--session <id>` to the opencode CLI to maintain context
3. Appends the new response to the conversation history

### Session Picker
- **Browse Sessions**: Use `:OpenCodeSessions` (`:OCSessions`) to view all saved sessions
- **Quick Access**: Sessions are sorted by modification time (newest first)
- **Load & Continue**: Select any session to load it into the response buffer and continue the conversation

### Draft Persistence
- **Unsaved Prompts**: Prompts are automatically saved as drafts when closing the prompt window
- **Draft Recovery**: Reopening the prompt window restores your previous work
- **Buffer Association**: Drafts are preserved per buffer context

### Session Commands
- **Continue from Buffer**: When viewing an OpenCode response or session, use `<leader>oc` to continue that session (automatically added)
- **Session Trigger**: Type `#session` (without parentheses) in the prompt window to open the session picker
- **New Sessions**: Select "New Session" from the picker to start fresh conversations

## 📋 Todo List Display

When OpenCode creates a todo list to plan its work, the tasks are displayed directly in the response buffer. This gives you visibility into what the AI is planning to do:

```
---
**Todo List:**

[~] Implement the new feature
[ ] Add unit tests !!
[ ] Update documentation !
[x] Review existing code
[-] Cancelled task
---
```

**Status Icons:**
| Icon | Status |
|------|--------|
| `[ ]` | Pending |
| `[~]` | In Progress |
| `[x]` | Completed |
| `[-]` | Cancelled |

**Priority Markers:**
| Marker | Priority |
|--------|----------|
| `!!!` | High |
| `!!` | Medium |
| `!` | Low |

## 🔧 How It Works

1. **Prompt Processing**: Your prompts are sent to the opencode CLI with the selected model and agent mode
2. **Streaming Display**: Responses stream in real-time to a vertical split buffer with markdown syntax highlighting
3. **Persistent Settings**: Model selection and project modes are persisted to `~/.local/share/nvim/`:
   - With `shared_buffer.nvim`: Uses `shared_opencode_config_state.json` and `shared_opencode_projects_state.json` with file watching
   - Without `shared_buffer.nvim`: Falls back to `opencode/config.json` and `opencode/projects.json`
4. **Session Storage**: Conversations are stored in `/tmp/opencode-nvim-sessions/` (ephemeral)
5. **Server Registry**: Cross-instance server coordination via `~/.local/share/nvim/opencode/servers.json`
6. **Smart Integration**: The plugin integrates with your current buffer context, allowing seamless file references

## 🐛 Troubleshooting

### Plugin doesn't load

Make sure you've called `setup()` in your plugin configuration:
```lua
require("opencode").setup()
```

### "opencode command not found"

Ensure the opencode CLI is installed and in your PATH:
```bash
# Check if opencode is available
which opencode

# If not, install from https://opencode.ai
```

### Telescope not working

Make sure telescope.nvim and its dependencies are installed and loaded before opencode.nvim.

### File references (@) not working

The `@` trigger requires telescope.nvim to be properly configured. Verify it's in your dependencies.

### Keymaps not working

If default keymaps aren't working:
1. Check if another plugin is using `<leader>oc`
2. Try setting a custom keymap in configuration
3. Verify `keymaps.enable_default` is not set to `false`

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

## 📄 License

MIT

## 🔗 Links

- [opencode CLI](https://opencode.ai) - The AI coding assistant CLI tool
- [Issue Tracker](https://github.com/fmpisantos/opencode.nvim/issues) - Report bugs or request features
