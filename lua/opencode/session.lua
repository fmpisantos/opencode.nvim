local M = {}

-- Cache for session settings to avoid repeated file I/O
M._settings_cache = {}

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
    -- Include backslash for Windows support
    local safe_path = config.get_cwd():gsub("[/:*?<>|\"\\]", "_"):gsub("^_+", "")
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
    local filepath = M.get_session_file(session_id)
    
    -- Invalidate cache for this session (keyed by filepath to avoid cross-project collisions)
    M._settings_cache[filepath] = nil

    local project_dir = M.get_project_session_dir()
    vim.fn.mkdir(project_dir, "p")
    
    -- Strip existing metadata lines from the start of content to avoid duplication
    local lines = vim.split(content, "\n", { plain = true })
    local clean_lines = {}
    local parsing_header = true
    
    for _, line in ipairs(lines) do
        if parsing_header then
            -- Skip specific metadata tags
            if line:match("^#agent%(") or line:match("^#agentic") or line:match("^#quick") then
                -- skip
            elseif line == "" then
                -- skip empty lines in header block to prevent fragmentation
            else
                parsing_header = false
                table.insert(clean_lines, line)
            end
        else
            table.insert(clean_lines, line)
        end
    end
    
    -- Prep metadata
    local metadata = {}
    if config.state.current_agent then
        table.insert(metadata, "#agent(" .. config.state.current_agent .. ")")
    end
    local effective_mode = config.state.mode or config.state.user_config.mode or "quick"
    if effective_mode == "agentic" then
        table.insert(metadata, "#agentic")
    elseif effective_mode == "quick" then
        table.insert(metadata, "#quick")
    end
    
    local meta_str = ""
    if #metadata > 0 then
        meta_str = table.concat(metadata, " ") .. "\n"
    end
    
    local full_content = meta_str .. table.concat(clean_lines, "\n")
    vim.fn.writefile(vim.split(full_content, "\n", { plain = true }), filepath)
end

--- Get session settings (agent, mode) from file
---@param session_id string
---@return table { agent = string|nil, mode = string|nil }
function M.get_session_settings(session_id)
    local filepath = M.get_session_file(session_id)
    
    -- Return cached settings if available (keyed by filepath)
    if M._settings_cache[filepath] then
        return M._settings_cache[filepath]
    end

    if vim.fn.filereadable(filepath) == 0 then
        return {}
    end

    local content = vim.fn.readfile(filepath)
    local settings = {}

    -- Scan first few lines
    for i, line in ipairs(content) do
        if i > 20 then break end -- Limit scan

        -- Check for agent
        local agent = line:match("#agent%(([^)]+)%)")
        if agent then settings.agent = agent end

        -- Check for mode tags
        if line:match("#agentic") then
            settings.mode = "agentic"
        elseif line:match("#quick") then
            settings.mode = "quick"
        end
    end

    -- Cache the result
    M._settings_cache[filepath] = settings
    return settings
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
                preview = (trimmed:sub(1, 50) .. (#trimmed > 50 and "..." or ""))
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
        config.state.current_agent = config.state.current_agent or "build"
        return vim.b[state.response_buf].opencode_session_id
    end
    return nil
end

return M
