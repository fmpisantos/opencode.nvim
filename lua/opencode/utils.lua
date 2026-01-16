local M = {}

-- =============================================================================
-- Utilities Module
-- =============================================================================
-- Shared utility functions for opencode.nvim

local config = require("opencode.config")

-- =============================================================================
-- File Utilities
-- =============================================================================

--- Check if a file path exists (handles both absolute and relative paths)
---@param filepath string The file path to check
---@return boolean exists Whether the file exists and is readable
function M.file_exists(filepath)
    -- First try the path as-is (handles absolute paths and paths relative to cwd)
    if vim.fn.filereadable(filepath) == 1 then
        return true
    end

    -- If it's a relative path, also try resolving it from cwd explicitly
    if not filepath:match("^[/~]") then
        local full_path = config.get_cwd() .. "/" .. filepath
        if vim.fn.filereadable(full_path) == 1 then
            return true
        end
    end

    return false
end

--- Extract file references from prompt content
--- Looks for patterns like @path/to/file or `@path/to/file`
--- Only returns files that actually exist; non-existent paths are treated as plain text
---@param content string The prompt content
---@return table files Array of unique file paths that exist
function M.extract_file_references(content)
    local files = {}
    local seen = {}

    -- Match patterns like @path/to/file or `@path/to/file`
    -- The pattern matches @ followed by a path (no spaces, backticks, or newlines)
    for file in content:gmatch("`@([^`%s\n]+)`") do
        if not seen[file] and M.file_exists(file) then
            table.insert(files, file)
            seen[file] = true
        end
    end

    -- Also match bare @file references (not wrapped in backticks)
    for file in content:gmatch("@([^%s`\n]+)") do
        -- Skip if it looks like an email or already captured
        if not file:match("@") and not seen[file] and M.file_exists(file) then
            table.insert(files, file)
            seen[file] = true
        end
    end

    return files
end

--- Discover MD files (like AGENT.md) by walking up the directory tree
--- from the source file to the project root (cwd)
---@param source_file? string The source file path (relative to cwd)
---@return table files Array of MD file paths found (from deepest to root)
function M.discover_md_files(source_file)
    local md_files = {}
    local cwd = config.get_cwd()

    -- Determine starting directory
    local start_dir
    if source_file and source_file ~= "" then
        -- Get the directory containing the source file
        local full_path = cwd .. "/" .. source_file
        start_dir = vim.fn.fnamemodify(full_path, ":h")
    else
        -- Use cwd if no source file
        start_dir = cwd
    end

    -- Normalize cwd (ensure no trailing slash for comparison)
    cwd = cwd:gsub("/$", "")

    -- Walk up the directory tree from start_dir to cwd
    local dir = start_dir
    local seen = {}

    while dir and dir:find(cwd, 1, true) == 1 do
        for _, md_file_name in ipairs(config.state.user_config.md_files or {}) do
            local md_path = dir .. "/" .. md_file_name
            if not seen[md_path] and vim.fn.filereadable(md_path) == 1 then
                -- Convert to relative path for --file flag
                local relative_path = md_path
                if md_path:sub(1, #cwd + 1) == cwd .. "/" then
                    relative_path = md_path:sub(#cwd + 2)
                end
                table.insert(md_files, relative_path)
                seen[md_path] = true
            end
        end

        -- Stop if we've reached cwd
        if dir == cwd then
            break
        end

        -- Move up one directory
        local parent = vim.fn.fnamemodify(dir, ":h")
        if parent == dir then
            -- We've reached the filesystem root
            break
        end
        dir = parent
    end

    return md_files
end

-- =============================================================================
-- String Utilities
-- =============================================================================

--- Parse lines from a string
---@param str string Input string
---@return table lines
function M.parse_lines(str)
    local lines = {}
    if str and str ~= "" then
        for line in str:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end
    end
    return lines
end

--- Check if content contains a session reference
---@param content string
---@return boolean
function M.has_session_reference(content)
    return content:match("#session%(([^)]+)%)") ~= nil
end

--- Extract session id from prompt if present
---@param prompt string The prompt text
---@return string prompt The prompt without session tag
---@return string|nil session_id The extracted session id or nil
function M.extract_session_from_prompt(prompt)
    local session_id = prompt:match("#session%(([^)]+)%)")
    if session_id then
        prompt = prompt:gsub("#session%([^)]+%)%s*", ""):gsub("%s*#session%([^)]+%)", "")
    end
    return prompt, session_id
end

-- =============================================================================
-- Display Utilities
-- =============================================================================

--- Append stderr output to display lines
---@param display_lines table Lines to append to
---@param stderr_output table Stderr lines
---@param is_running? boolean Whether process is still running
function M.append_stderr_block(display_lines, stderr_output, is_running)
    if #stderr_output == 0 then
        return
    end

    table.insert(display_lines, "")
    if is_running then
        table.insert(display_lines, "**stderr output (process still running):**")
    else
        table.insert(display_lines, "**stderr output:**")
    end
    table.insert(display_lines, "```")
    for _, line in ipairs(stderr_output) do
        table.insert(display_lines, line)
    end
    table.insert(display_lines, "```")
end

--- Format todo items into display lines
---@param todos table Array of todo items { id, content, status, priority }
---@return table lines Formatted display lines
function M.format_todo_list(todos)
    if not todos or #todos == 0 then
        return {}
    end

    local lines = {}
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "**Todo List:**")
    table.insert(lines, "")

    -- Status icons
    local status_icons = {
        pending = "[ ]",
        in_progress = "[~]",
        completed = "[x]",
        cancelled = "[-]",
    }

    -- Priority indicators
    local priority_markers = {
        high = "!!!",
        medium = "!!",
        low = "!",
    }

    for _, todo in ipairs(todos) do
        local icon = status_icons[todo.status] or "[ ]"
        local priority = priority_markers[todo.priority] or ""
        local line = string.format("%s %s %s", icon, todo.content or "", priority)
        table.insert(lines, line)
    end

    table.insert(lines, "---")
    table.insert(lines, "")

    return lines
end

-- =============================================================================
-- Command Building
-- =============================================================================

--- Build opencode command with common options
--- NOTE: Callers are responsible for adding --model flag before calling this function.
--- This function does NOT add --model to avoid duplication with caller-specific model handling.
---@param base_args table Base command arguments (should include --model if needed)
---@param prompt? string Optional prompt to append
---@param files? table Optional array of file paths to attach via --file
---@return table cmd Complete command
function M.build_opencode_cmd(base_args, prompt, files)
    local cmd = vim.deepcopy(base_args)
    -- Add files with --file flag
    if files and #files > 0 then
        for _, file in ipairs(files) do
            table.insert(cmd, "--file")
            table.insert(cmd, file)
        end
    end
    if prompt then
        -- Use -- to separate options from the positional message argument
        -- This prevents the CLI from interpreting the message as file paths
        table.insert(cmd, "--")
        table.insert(cmd, prompt)
    end
    return cmd
end

return M
