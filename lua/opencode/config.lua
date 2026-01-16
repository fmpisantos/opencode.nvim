local M = {}

-- =============================================================================
-- Configuration Module
-- =============================================================================
-- Centralized configuration and state management for opencode.nvim

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
    -- Mode: "quick" (one-shot, files via --file) or "agentic" (server mode with full tool access)
    mode = "quick",
    -- Server settings for agentic mode
    server = {
        port = 0, -- 0 = random available port
        hostname = "127.0.0.1",
    },
}

-- =============================================================================
-- Paths
-- =============================================================================

M.paths = {
    config_dir = vim.fn.stdpath("data") .. "/opencode",
    config_file = vim.fn.stdpath("data") .. "/opencode/config.json",
    project_config_file = vim.fn.stdpath("data") .. "/opencode/projects.json",
    sessions_dir = "/tmp/opencode-nvim-sessions",
}

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
---@field project_modes table

M.state = {
    selected_model = nil,
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

    -- Per-project mode preferences (loaded from disk)
    project_modes = {}, -- { [cwd] = "quick" | "agentic" }
}

-- =============================================================================
-- Config File Management
-- =============================================================================

--- Load model configuration from disk
function M.load_config()
    if vim.fn.filereadable(M.paths.config_file) == 1 then
        local content = vim.fn.readfile(M.paths.config_file)
        if #content > 0 then
            local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
            if ok and data and data.model then
                M.state.selected_model = data.model
            end
        end
    end
end

--- Save model configuration to disk
function M.save_config()
    vim.fn.mkdir(M.paths.config_dir, "p")
    local data = { model = M.state.selected_model }
    vim.fn.writefile({ vim.json.encode(data) }, M.paths.config_file)
end

--- Load project modes from disk
function M.load_project_modes()
    if vim.fn.filereadable(M.paths.project_config_file) == 1 then
        local content = vim.fn.readfile(M.paths.project_config_file)
        if #content > 0 then
            local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
            if ok and data and data.project_modes then
                M.state.project_modes = data.project_modes
            end
        end
    end
end

--- Save project modes to disk
function M.save_project_modes()
    vim.fn.mkdir(M.paths.config_dir, "p")
    local data = { project_modes = M.state.project_modes }
    vim.fn.writefile({ vim.json.encode(data) }, M.paths.project_config_file)
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
    local cwd = M.get_cwd()
    if M.state.project_modes[cwd] then
        return M.state.project_modes[cwd]
    end
    return M.state.user_config.mode or "quick"
end

--- Set the mode for the current project
---@param mode string "quick" or "agentic"
---@return boolean success
function M.set_project_mode(mode)
    if mode ~= "quick" and mode ~= "agentic" then
        vim.notify("Invalid mode: " .. tostring(mode) .. ". Use 'quick' or 'agentic'.", vim.log.levels.ERROR)
        return false
    end
    local cwd = M.get_cwd()
    M.state.project_modes[cwd] = mode
    M.save_project_modes()
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

    -- Load persisted configurations
    M.load_config()
    M.load_project_modes()
end

return M
