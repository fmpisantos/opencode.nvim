local M = {}

-- =============================================================================
-- Configuration Module
-- =============================================================================
-- Centralized configuration and state management for opencode.nvim
-- Uses shared_buffer.nvim for persistent state management

-- =============================================================================
-- Constants
-- =============================================================================

M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.SPINNER_INTERVAL_MS = 80
M.SESSION_SEPARATOR = "\n\n===============================================================================\n\n"
M.NEW_SESSION_LABEL = "(New Session)"

-- =============================================================================
-- Default Configuration
-- =============================================================================

M.defaults = {
    -- Window dimensions
    prompt_window = {
        width = 60,
        height = 10,
    },
    review_window = {
        width = 60,
        height = 8,
    },
    -- Response buffer options
    response_buffer = {
        wrap = true, -- Enable line wrapping in response buffer
    },
    -- Timeout in milliseconds (default 2 minutes)
    -- Set to -1 to disable timeout (recommended for agentic mode)
    timeout_ms = 120000,
    -- Keymaps
    keymaps = {
        enable_default = true,
        open_prompt = "<leader>oc",
    },
    -- MD files to auto-discover up the directory tree (like AGENT.md)
    -- These files provide hierarchical context to the AI
    md_files = { "AGENT.md", "AGENTS.md" },
    -- Mode: "quick" or "agentic"
    -- - "quick": Uses `opencode run` directly for one-shot queries with files via --file
    -- - "agentic": Starts a local server via `opencode serve` and uses
    --              `opencode run --attach <url>` to connect to it. This avoids
    --              MCP server cold boot times on every request.
    --              See: https://opencode.ai/docs/cli/#attach
    mode = "quick",
    -- Default agent to use ("build" or "plan")
    agent = "build",
    -- Server settings for agentic mode
    server = {
        -- Ordered list of ports to try. The server will use the first available port.
        -- If all ports are in use, falls back to port 0 (OS-assigned random port).
        ports = { 4096, 4097, 4098, 4099, 4100, 4101, 4102, 4103, 4104, 4105 },
        hostname = "127.0.0.1",
    },
}

-- =============================================================================
-- Paths (only sessions_dir is still needed for temporary session files)
-- =============================================================================

M.paths = {
    sessions_dir = "/tmp/opencode-nvim-sessions",
}

-- =============================================================================
-- Shared Buffer State Management
-- =============================================================================

-- Persistent state via shared_buffer.nvim (optional dependency)
-- If shared_buffer is not available, falls back to direct file-based persistence
local shared_buffer_ok, shared_buffer = pcall(require, "shared_buffer")

local config_state, save_config_state
local project_state, save_project_state

if shared_buffer_ok then
    -- Global config (model selection) - stored in ~/.local/share/nvim/shared_opencode_config_state.json
    config_state, save_config_state = shared_buffer.setup("opencode_config")
    -- Project modes - stored in ~/.local/share/nvim/shared_opencode_projects_state.json
    project_state, save_project_state = shared_buffer.setup("opencode_projects")
else
    -- Fallback: direct file-based persistence
    local config_file = vim.fn.stdpath("data") .. "/opencode/config.json"
    local project_file = vim.fn.stdpath("data") .. "/opencode/projects.json"

    -- Load config state from file
    config_state = { bufnr = -1 }
    if vim.fn.filereadable(config_file) == 1 then
        local content = vim.fn.readfile(config_file)
        if #content > 0 then
            local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
            if ok and data then
                config_state = data
            end
        end
    end

    -- Fallback save functions
    save_config_state = function(state)
        vim.fn.mkdir(vim.fn.fnamemodify(config_file, ":h"), "p")
        vim.fn.writefile({ vim.json.encode(state) }, config_file)
    end

    -- Project state is no longer persisted
    save_project_state = function(_) end
end

-- =============================================================================
-- State (mutable)
-- =============================================================================

---@class OpenCodeState
---@field selected_model string|nil
---@field draft_content table|nil
---@field draft_cursor table|nil
---@field user_config table
---@field is_initialized boolean
---@field current_session_id string|nil
---@field current_session_name string|nil
---@field response_buf number|nil
---@field response_win number|nil
---@field prompt_buf number|nil
---@field prompt_win number|nil
---@field active_requests table
---@field next_request_id number
---@field servers table
---@field mode string|nil

M.state = {
    -- Persistent state (loaded from shared_buffer or fallback on startup)
    selected_model = config_state.model,
    
    -- Runtime-only state
    mode = nil, -- Current mode (quick/agentic)
    draft_content = nil,
    draft_cursor = nil,
    user_config = vim.deepcopy(M.defaults),
    is_initialized = false,

    -- Session state
    current_session_id = nil,
    current_session_name = nil,
    response_buf = nil,
    response_win = nil,

    -- Prompt window state (for attach functionality)
    prompt_buf = nil,
    prompt_win = nil,

    -- Active requests tracking (for cancellation)
    active_requests = {}, -- table of { id = { system_obj, cleanup_fn } }
    next_request_id = 0,

    -- Server management state (for agentic mode)
    -- Keyed by cwd: { [cwd] = { process = system_obj, port = number, url = string, starting = bool } }
    servers = {},
}

-- =============================================================================
-- Config Persistence (via shared_buffer)
-- =============================================================================

--- Save model configuration to shared_buffer
function M.save_config()
    config_state.model = M.state.selected_model
    save_config_state(config_state)
end

-- =============================================================================
-- Accessors
-- =============================================================================

--- Get current working directory (evaluated at call time, not module load)
---@return string
function M.get_cwd()
    return vim.fn.getcwd()
end

--- Get model display name
---@return string
function M.get_model_display()
    if M.state.selected_model and M.state.selected_model ~= "" then
        return M.state.selected_model:match("/(.+)$") or M.state.selected_model
    end
    return "default"
end

--- Get the mode for the current project
---@return string mode "quick" or "agentic"
function M.get_project_mode()
    -- Prioritize runtime state
    if M.state.mode then
        return M.state.mode
    end
    -- Fallback to default config
    return M.state.user_config.mode or "quick"
end

--- Set the mode for the current project (Runtime only)
---@param mode string "quick" or "agentic"
---@return boolean success
function M.set_project_mode(mode)
    if mode ~= "quick" and mode ~= "agentic" then
        vim.notify("Invalid mode: " .. tostring(mode) .. ". Use 'quick' or 'agentic'.", vim.log.levels.ERROR)
        return false
    end
    M.state.mode = mode
    return true
end

--- Get session display name for title
---@return string
function M.get_session_display()
    if M.state.current_session_name then
        local display = M.state.current_session_name:sub(1, 20)
        if #M.state.current_session_name > 20 then
            display = display .. "..."
        end
        return display
    elseif M.state.current_session_id then
        return "Session: " .. M.state.current_session_id:sub(1, 15)
    end
    return "New"
end

-- =============================================================================
-- Setup
-- =============================================================================

--- Initialize configuration (called once at setup)
---@param opts? table User configuration options
function M.setup(opts)
    -- Merge user config with defaults
    if opts then
        M.state.user_config = vim.tbl_deep_extend("force", M.defaults, opts)
    end

    -- State is already loaded from shared_buffer at module load time
    -- No need to call load_config() or load_project_modes()
end

return M
