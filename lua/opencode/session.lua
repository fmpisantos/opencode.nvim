local M = {}

-- =============================================================================
-- Session Module
-- =============================================================================
-- Session management for opencode.nvim

local config = require("opencode.config")

-- =============================================================================
-- Session File Management
-- =============================================================================

--- Get a safe directory name from the current working directory
---@return string
function M.get_project_session_dir()
    -- Replace path separators and special chars with underscores
    local safe_path = config.get_cwd():gsub("[/\\:*?\"<>|]", "_"):gsub("^_+", "")
    return config.paths.sessions_dir .. "/" .. safe_path
end

--- Get session file path
---@param session_id string
---@return string
function M.get_session_file(session_id)
    return M.get_project_session_dir() .. "/" .. session_id .. ".md"
end

--- Save session content to file
---@param session_id string
---@param content string
function M.save_session(session_id, content)
    local project_dir = M.get_project_session_dir()
    vim.fn.mkdir(project_dir, "p")
    local filepath = M.get_session_file(session_id)
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), filepath)
end

--- Load session content from file
---@param session_id string
---@return string|nil
function M.load_session(session_id)
    local filepath = M.get_session_file(session_id)
    if vim.fn.filereadable(filepath) == 1 then
        local content = vim.fn.readfile(filepath)
        return table.concat(content, "\n")
    end
    return nil
end

--- List all available sessions for the current project
---@return table sessions List of { id, name, mtime, display }
function M.list_sessions()
    local sessions = {}
    local project_dir = M.get_project_session_dir()
    vim.fn.mkdir(project_dir, "p")
    local files = vim.fn.glob(project_dir .. "/*.md", false, true)

    for _, filepath in ipairs(files) do
        local filename = vim.fn.fnamemodify(filepath, ":t:r")
        local mtime = vim.fn.getftime(filepath)
        local content = vim.fn.readfile(filepath)

        -- Extract first meaningful line as name preview
        local preview = "Empty session"
        for _, line in ipairs(content) do
            local trimmed = vim.trim(line)
            if trimmed ~= "" and not trimmed:match("^[#*`-]+$") and not trimmed:match("^%*%*") then
                preview = trimmed:sub(1, 50)
                if #trimmed > 50 then
                    preview = preview .. "..."
                end
                break
            end
        end

        table.insert(sessions, {
            id = filename,
            name = preview,
            mtime = mtime,
            display = os.date("%Y-%m-%d %H:%M", mtime) .. " - " .. preview,
        })
    end

    -- Sort by modification time (newest first)
    table.sort(sessions, function(a, b)
        return a.mtime > b.mtime
    end)

    return sessions
end

-- =============================================================================
-- Session State Management
-- =============================================================================

--- Start a new session (session ID will be set when we get it from CLI)
function M.start_new_session()
    config.state.current_session_id = nil
    config.state.current_session_name = nil
end

--- Clear current session (for new prompt via <leader>oc)
--- Note: This no longer closes the response buffer to preserve user's view
function M.clear_session()
    config.state.current_session_id = nil
    config.state.current_session_name = nil
    -- Don't close response buffer - user may want to keep it visible
    -- The response buffer will be reused or a new one created when needed
end

--- Get session id from response buffer if current buffer is one
---@return string|nil
function M.get_session_from_current_buffer()
    local current_buf = vim.api.nvim_get_current_buf()
    local state = config.state
    if current_buf == state.response_buf and state.response_buf and vim.api.nvim_buf_is_valid(state.response_buf) then
        return vim.b[state.response_buf].opencode_session_id
    end
    return nil
end

return M
