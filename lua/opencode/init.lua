local M = {}

-- =============================================================================
-- Constants
-- =============================================================================

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL_MS = 80
local SESSION_SEPARATOR = "\n\n===============================================================================\n\n"
local NEW_SESSION_LABEL = "(New Session)"

-- =============================================================================
-- Default Configuration
-- =============================================================================

local default_config = {
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
    timeout_ms = 120000,
    -- Keymaps
    keymaps = {
        enable_default = true,
        open_prompt = "<leader>oc",
    },
    -- MD files to auto-discover up the directory tree (like AGENT.md)
    -- These files provide hierarchical context to the AI
    md_files = { "AGENT.md", "AGENTS.md" },
}

-- =============================================================================
-- State
-- =============================================================================

local config_dir = vim.fn.stdpath("data") .. "/opencode"
local config_file = config_dir .. "/config.json"
local sessions_dir = "/tmp/opencode-nvim-sessions"
local selected_model = nil
local draft_content = nil
local draft_cursor = nil
local user_config = vim.deepcopy(default_config)
local is_initialized = false

-- Session state
local current_session_id = nil
local current_session_name = nil
local response_buf = nil
local response_win = nil

-- Active requests tracking (for cancellation)
local active_requests = {} -- table of { id = { system_obj, cleanup_fn } }
local next_request_id = 0

-- =============================================================================
-- Config Management
-- =============================================================================

local function load_config()
    if vim.fn.filereadable(config_file) == 1 then
        local content = vim.fn.readfile(config_file)
        if #content > 0 then
            local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
            if ok and data and data.model then
                selected_model = data.model
            end
        end
    end
end

local function save_config()
    vim.fn.mkdir(config_dir, "p")
    local data = { model = selected_model }
    vim.fn.writefile({ vim.json.encode(data) }, config_file)
end

local function get_model_display()
    if selected_model and selected_model ~= "" then
        return selected_model:match("/(.+)$") or selected_model
    end
    return "default"
end

-- Load config on module load
load_config()

-- =============================================================================
-- Helper: Get Current Working Directory
-- =============================================================================

--- Get current working directory (evaluated at call time, not module load)
---@return string
local function get_cwd()
    return vim.fn.getcwd()
end

-- =============================================================================
-- Session Management
-- =============================================================================

--- Get a safe directory name from the current working directory
---@return string
local function get_project_session_dir()
    -- Replace path separators and special chars with underscores
    local safe_path = get_cwd():gsub("[/\\:*?\"<>|]", "_"):gsub("^_+", "")
    return sessions_dir .. "/" .. safe_path
end

--- Get session file path
---@param session_id string
---@return string
local function get_session_file(session_id)
    return get_project_session_dir() .. "/" .. session_id .. ".md"
end

--- Save session content to file
---@param session_id string
---@param content string
local function save_session(session_id, content)
    local project_dir = get_project_session_dir()
    vim.fn.mkdir(project_dir, "p")
    local filepath = get_session_file(session_id)
    vim.fn.writefile(vim.split(content, "\n", { plain = true }), filepath)
end

--- Load session content from file
---@param session_id string
---@return string|nil
local function load_session(session_id)
    local filepath = get_session_file(session_id)
    if vim.fn.filereadable(filepath) == 1 then
        local content = vim.fn.readfile(filepath)
        return table.concat(content, "\n")
    end
    return nil
end

--- List all available sessions for the current project
---@return table sessions List of { id, name, mtime }
local function list_sessions()
    local sessions = {}
    local project_dir = get_project_session_dir()
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

--- Start a new session (session ID will be set when we get it from CLI)
local function start_new_session()
    current_session_id = nil
    current_session_name = nil
end

--- Clear current session (for new prompt via <leader>oc)
local function clear_session()
    current_session_id = nil
    current_session_name = nil
    -- Close existing response buffer if any
    if response_buf and vim.api.nvim_buf_is_valid(response_buf) then
        vim.api.nvim_buf_delete(response_buf, { force = true })
    end
    response_buf = nil
    response_win = nil
end

-- =============================================================================
-- Helper Functions
-- =============================================================================

--- Create or reuse a response buffer in a vertical split
---@param name string Buffer name
---@param clear boolean Whether to clear the buffer
---@return number buf Buffer handle
---@return number win Window handle
local function create_response_split(name, clear)
    -- Reuse existing buffer if valid
    if response_buf and vim.api.nvim_buf_is_valid(response_buf) then
        -- Check if buffer is already displayed in a window
        local wins = vim.fn.win_findbuf(response_buf)
        if #wins > 0 then
            response_win = wins[1]
            vim.api.nvim_set_current_win(response_win)
        else
            -- Buffer exists but not displayed, open in split
            vim.cmd("vsplit")
            response_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(response_win, response_buf)
        end

        -- Apply wrap setting to window
        vim.wo[response_win].wrap = user_config.response_buffer.wrap

        if clear then
            vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, {})
        end

        return response_buf, response_win
    end

    -- Create new buffer
    response_buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("vsplit")
    response_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(response_win, response_buf)

    vim.bo[response_buf].buftype = "nofile"
    vim.bo[response_buf].bufhidden = "hide"
    vim.bo[response_buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(response_buf, name)

    -- Apply wrap setting to window
    vim.wo[response_win].wrap = user_config.response_buffer.wrap

    -- Store session id in buffer variable for reference
    vim.b[response_buf].opencode_session_id = current_session_id

    -- Keymap to close (hide) the buffer
    vim.keymap.set("n", "q", function()
        if response_win and vim.api.nvim_win_is_valid(response_win) then
            vim.api.nvim_win_close(response_win, false)
            response_win = nil
        end
    end, { buffer = response_buf, noremap = true, silent = true, desc = "Close OpenCode response" })

    return response_buf, response_win
end

--- Toggle the response buffer visibility
local function toggle_response_buffer()
    if not response_buf or not vim.api.nvim_buf_is_valid(response_buf) then
        vim.notify("No OpenCode session active. Use <leader>oc to start one.", vim.log.levels.INFO)
        return
    end

    local wins = vim.fn.win_findbuf(response_buf)
    if #wins > 0 then
        -- Buffer is visible, close the window
        vim.api.nvim_win_close(wins[1], false)
        response_win = nil
    else
        -- Buffer is hidden, show it in a split
        vim.cmd("vsplit")
        response_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(response_win, response_buf)
        -- Apply wrap setting to window
        vim.wo[response_win].wrap = user_config.response_buffer.wrap
    end
end

--- Create a centered floating window
---@param opts { width: number, height: number, title: string, filetype: string, name: string }
---@return number buf Buffer handle
---@return number win Window handle
local function create_floating_window(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = opts.width,
        height = opts.height,
        col = (vim.o.columns - opts.width) / 2,
        row = (vim.o.lines - opts.height) / 2,
        style = "minimal",
        border = "rounded",
        title = opts.title,
        title_pos = "center",
    })

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = opts.filetype or "opencode"
    vim.api.nvim_buf_set_name(buf, opts.name)

    return buf, win
end

--- Append stderr output to display lines
---@param display_lines table Lines to append to
---@param stderr_output table Stderr lines
---@param is_running? boolean Whether process is still running
local function append_stderr_block(display_lines, stderr_output, is_running)
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

--- Build opencode command with common options
---@param base_args table Base command arguments
---@param prompt? string Optional prompt to append
---@param files? table Optional array of file paths to attach via --file
---@return table cmd Complete command
local function build_opencode_cmd(base_args, prompt, files)
    local cmd = vim.deepcopy(base_args)
    if selected_model and selected_model ~= "" then
        table.insert(cmd, "--model")
        table.insert(cmd, selected_model)
    end
    -- Add files with --file flag
    if files and #files > 0 then
        for _, file in ipairs(files) do
            table.insert(cmd, "--file")
            table.insert(cmd, file)
        end
    end
    if prompt then
        table.insert(cmd, prompt)
    end
    return cmd
end

--- Parse lines from a string
---@param str string Input string
---@return table lines
local function parse_lines(str)
    local lines = {}
    if str and str ~= "" then
        for line in str:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end
    end
    return lines
end

--- Extract file references from prompt content
--- Looks for patterns like @path/to/file or `@path/to/file`
---@param content string The prompt content
---@return table files Array of unique file paths that exist
local function extract_file_references(content)
    local files = {}
    local seen = {}

    -- Match patterns like @path/to/file or `@path/to/file`
    -- The pattern matches @ followed by a path (no spaces, backticks, or newlines)
    for file in content:gmatch("`@([^`%s\n]+)`") do
        if not seen[file] and vim.fn.filereadable(file) == 1 then
            table.insert(files, file)
            seen[file] = true
        end
    end

    -- Also match bare @file references (not wrapped in backticks)
    for file in content:gmatch("@([^%s`\n]+)") do
        -- Skip if it looks like an email or already captured
        if not file:match("@") and not seen[file] and vim.fn.filereadable(file) == 1 then
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
local function discover_md_files(source_file)
    local md_files = {}
    local cwd = get_cwd()

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
        for _, md_file_name in ipairs(user_config.md_files or {}) do
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
-- Active Request Management
-- =============================================================================

--- Register an active request for tracking/cancellation
---@param system_obj table The vim.system object
---@param cleanup_fn? function Optional cleanup function to call on cancel
---@return number request_id The ID of the registered request
local function register_request(system_obj, cleanup_fn)
    next_request_id = next_request_id + 1
    active_requests[next_request_id] = {
        system_obj = system_obj,
        cleanup_fn = cleanup_fn,
    }
    return next_request_id
end

--- Unregister a completed request
---@param request_id number The request ID to unregister
local function unregister_request(request_id)
    active_requests[request_id] = nil
end

--- Cancel a specific request
---@param request_id number The request ID to cancel
local function cancel_request(request_id)
    local request = active_requests[request_id]
    if request then
        if request.system_obj then
            pcall(function() request.system_obj:kill(9) end)
        end
        if request.cleanup_fn then
            pcall(request.cleanup_fn)
        end
        active_requests[request_id] = nil
    end
end

--- Cancel all active requests
local function cancel_all_requests()
    local count = 0
    for id, _ in pairs(active_requests) do
        cancel_request(id)
        count = count + 1
    end
    return count
end

--- Get count of active requests
---@return number
local function get_active_request_count()
    local count = 0
    for _ in pairs(active_requests) do
        count = count + 1
    end
    return count
end

-- =============================================================================
-- Response Parsing
-- =============================================================================

--- Parse opencode JSON output and extract assistant text
---@param json_lines table Lines of JSON output
---@return string|nil response Response text or nil
---@return string|nil error Error message or nil
---@return boolean is_thinking Whether model is thinking
local function parse_opencode_response(json_lines)
    local response_parts = {}
    local error_message = nil
    local is_thinking = false

    for _, line in ipairs(json_lines) do
        if line and line ~= "" then
            local ok, data = pcall(vim.json.decode, line)
            if ok and data then
                if data.type == "error" and data.error then
                    local err = data.error
                    error_message = err.data and err.data.message
                        or err.message
                        or err.name
                        or "Unknown error"
                elseif data.type == "thinking" or (data.part and data.part.type == "thinking") then
                    is_thinking = true
                elseif data.type == "text" and data.part and data.part.type == "text" then
                    is_thinking = false
                    table.insert(response_parts, data.part.text or "")
                end
            end
        end
    end

    if error_message then
        return nil, error_message, false
    end

    return table.concat(response_parts, ""), nil, is_thinking
end

-- =============================================================================
-- Spinner
-- =============================================================================

---@class Spinner
---@field private buf number
---@field private is_running boolean
---@field private timer number|nil
---@field private idx number
---@field private prefix string
---@field private header_lines table
local Spinner = {}
Spinner.__index = Spinner

---@param buf number Buffer handle
---@param prefix string Loading message prefix
---@param header_lines table Header lines to display
---@return Spinner
function Spinner.new(buf, prefix, header_lines)
    local self = setmetatable({}, Spinner)
    self.buf = buf
    self.is_running = true
    self.timer = nil
    self.idx = 1
    self.prefix = prefix
    self.header_lines = header_lines
    return self
end

function Spinner:start()
    local function update()
        if not self.is_running or not vim.api.nvim_buf_is_valid(self.buf) then
            return
        end

        local display_lines = vim.deepcopy(self.header_lines)
        table.insert(display_lines, self.prefix .. SPINNER_FRAMES[self.idx])
        table.insert(display_lines, "")
        vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, display_lines)

        self.idx = (self.idx % #SPINNER_FRAMES) + 1

        if self.is_running then
            self.timer = vim.fn.timer_start(SPINNER_INTERVAL_MS, function()
                update()
            end)
        end
    end

    self.timer = vim.fn.timer_start(0, function()
        update()
    end)
end

function Spinner:stop()
    self.is_running = false
    if self.timer then
        vim.fn.timer_stop(self.timer)
        self.timer = nil
    end
end

-- =============================================================================
-- Run OpenCode
-- =============================================================================

--- Extract session id from prompt if present
---@param prompt string The prompt text
---@return string prompt The prompt without session tag
---@return string|nil session_id The extracted session id or nil
local function extract_session_from_prompt(prompt)
    local session_id = prompt:match("#session%(([^)]+)%)")
    if session_id then
        prompt = prompt:gsub("#session%([^)]+%)%s*", ""):gsub("%s*#session%([^)]+%)", "")
    end
    return prompt, session_id
end

--- Format todo items into display lines
---@param todos table Array of todo items { id, content, status, priority }
---@return table lines Formatted display lines
local function format_todo_list(todos)
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

--- Parse streaming JSON output and return current state
---@param json_lines table Lines of JSON output received so far
---@return table response_lines Lines of response text
---@return string|nil error_message Error if any
---@return boolean is_thinking Whether model is currently thinking
---@return string|nil current_tool Current tool being executed (if any)
---@return string|nil tool_status Status of the tool execution
---@return string|nil cli_session_id The CLI session ID from opencode
---@return table|nil todos Current todo list (if any)
local function parse_streaming_response(json_lines)
    local response_lines = {}
    local error_message = nil
    local is_thinking = false
    local current_tool = nil
    local tool_status = nil
    local cli_session_id = nil
    local todos = nil

    for _, line in ipairs(json_lines) do
        if line and line ~= "" then
            local ok, data = pcall(vim.json.decode, line)
            if ok and data then
                -- Capture CLI session ID from any message
                if data.sessionID and not cli_session_id then
                    cli_session_id = data.sessionID
                end

                if data.type == "error" and data.error then
                    local err = data.error
                    error_message = err.data and err.data.message
                        or err.message
                        or err.name
                        or "Unknown error"
                elseif data.type == "thinking" or (data.part and data.part.type == "thinking") then
                    is_thinking = true
                    current_tool = nil
                elseif data.type == "text" and data.part and data.part.type == "text" then
                    is_thinking = false
                    current_tool = nil
                    local text = data.part.text or ""
                    -- Split the text by newlines and add each line separately
                    local text_lines = vim.split(text, "\n", { plain = true })
                    for _, text_line in ipairs(text_lines) do
                        table.insert(response_lines, text_line)
                    end
                elseif data.type == "tool_use" and data.part then
                    -- Tool use event (includes tool name and state)
                    is_thinking = false
                    current_tool = data.part.tool or "unknown tool"
                    local state = data.part.state
                    if state then
                        tool_status = state.status or "running"
                        -- Capture todo list from todowrite tool
                        if data.part.tool == "todowrite" and state.input and state.input.todos then
                            todos = state.input.todos
                        end
                    end
                elseif data.type == "tool-call" and data.part then
                    -- Tool is being called (legacy format)
                    is_thinking = false
                    current_tool = data.part.toolName or data.part.name or "unknown tool"
                    tool_status = "calling"
                elseif data.type == "tool-result" and data.part then
                    -- Tool finished (legacy format)
                    current_tool = data.part.toolName or data.part.name or "tool"
                    tool_status = "completed"
                end
            end
        end
    end

    return response_lines, error_message, is_thinking, current_tool, tool_status, cli_session_id, todos
end

--- Run opencode with session support
---@param prompt string The prompt to send
---@param files? table Optional array of file paths to attach via --file
---@param source_file? string Optional source file for MD file discovery
local function run_opencode(prompt, files, source_file)
    if not prompt or prompt == "" then
        return
    end

    -- Extract CLI session id from prompt if present (for continuation)
    local cli_session_id
    prompt, cli_session_id = extract_session_from_prompt(prompt)

    -- Determine if this is a continuation of an existing session
    local is_continuation = cli_session_id ~= nil

    -- Determine agent mode
    local agent = "build"
    if prompt:match("#plan") then
        agent = "plan"
        prompt = prompt:gsub("#plan%s*", ""):gsub("%s*#plan", "")
    end

    -- Set current session if continuing
    if cli_session_id then
        current_session_id = cli_session_id
        current_session_name = nil
    end

    -- Get existing content if continuing
    local existing_content = {}
    if is_continuation and cli_session_id then
        -- Load from file if we have a session id
        local saved_content = load_session(cli_session_id)
        if saved_content then
            existing_content = vim.split(saved_content, "\n", { plain = true })
        elseif response_buf and vim.api.nvim_buf_is_valid(response_buf) then
            existing_content = vim.api.nvim_buf_get_lines(response_buf, 0, -1, false)
        end
    end

    local buf, _ = create_response_split("OpenCode Response", not is_continuation)

    -- Update buffer's session id (may be nil for new sessions until we get it from CLI)
    vim.b[buf].opencode_session_id = current_session_id

    -- Collect all files to attach:
    -- 1. Files explicitly passed in (e.g., source buffer)
    -- 2. Files referenced with @path in the prompt
    -- 3. MD files discovered up the directory tree (AGENT.md, etc.)
    local all_files = files and vim.deepcopy(files) or {}
    local seen_files = {}
    for _, f in ipairs(all_files) do
        seen_files[f] = true
    end

    -- Add files referenced in prompt
    local prompt_files = extract_file_references(prompt)
    for _, f in ipairs(prompt_files) do
        if not seen_files[f] then
            table.insert(all_files, f)
            seen_files[f] = true
        end
    end

    -- Discover and add MD files (AGENT.md, etc.) from directory hierarchy
    local md_files = discover_md_files(source_file)
    for _, f in ipairs(md_files) do
        if not seen_files[f] then
            table.insert(all_files, f)
            seen_files[f] = true
        end
    end

    -- Build command with --session flag if continuing
    local base_cmd = { "opencode", "run", "--agent", agent, "--format", "json" }
    if cli_session_id then
        table.insert(base_cmd, "--session")
        table.insert(base_cmd, cli_session_id)
    end
    local cmd = build_opencode_cmd(base_cmd, prompt, all_files)

    -- Build header for this query
    local cmd_display = table.concat(cmd, " "):gsub("\n", "\\n")
    local header_lines = {
        "**Command:** `" .. cmd_display .. "`",
        "",
        "**Query:**",
    }
    vim.list_extend(header_lines, vim.split(prompt, "\n", { plain = true }))
    vim.list_extend(header_lines, { "", "---", "" })

    -- If continuing, prepend separator and existing content
    local display_prefix = {}
    if is_continuation and #existing_content > 0 then
        display_prefix = vim.deepcopy(existing_content)
        vim.list_extend(display_prefix, vim.split(SESSION_SEPARATOR, "\n", { plain = true }))
    end

    -- Combine prefix with header
    local full_header = vim.deepcopy(display_prefix)
    vim.list_extend(full_header, header_lines)

    -- State for streaming updates
    local json_lines = {}
    local stderr_output = {}
    local system_obj = nil
    local is_running = true
    local run_start_time = nil
    local spinner_idx = 1
    local update_timer = nil
    local request_id = nil

    -- Function to update display with current streaming state
    local function update_display()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end

        local display_lines = vim.deepcopy(full_header)
        local model_info = selected_model and (" [" .. get_model_display() .. "]") or ""

        -- Add spinner
        local spinner_char = SPINNER_FRAMES[spinner_idx]
        spinner_idx = (spinner_idx % #SPINNER_FRAMES) + 1

        local response_lines, err, is_thinking, current_tool, tool_status, new_cli_session_id, todos = parse_streaming_response(json_lines)

        -- Capture CLI session ID if we don't have one yet
        if new_cli_session_id and not current_session_id then
            current_session_id = new_cli_session_id
            vim.b[buf].opencode_session_id = current_session_id
        end

        if is_running then
            -- Build status line with elapsed time
            local elapsed = ""
            if run_start_time then
                local seconds = math.floor((vim.loop.now() - run_start_time) / 1000)
                elapsed = " (" .. seconds .. "s)"
            end
            local status_text

            if is_thinking then
                status_text = "**Status:** Thinking" .. elapsed .. " " .. spinner_char
            elseif current_tool then
                if tool_status == "calling" or tool_status == "running" then
                    status_text = "**Status:** Executing `" .. current_tool .. "`" .. elapsed .. " " .. spinner_char
                else
                    status_text = "**Status:** Completed `" .. current_tool .. "`" .. elapsed .. " " .. spinner_char
                end
            else
                status_text = "**Status:** Running" .. model_info .. elapsed .. " " .. spinner_char
            end

            table.insert(display_lines, status_text)
            table.insert(display_lines, "")
        end

        -- Add todo list if present
        if todos and #todos > 0 then
            vim.list_extend(display_lines, format_todo_list(todos))
        end

        if err then
            table.insert(display_lines, "**Error:** " .. err)
            append_stderr_block(display_lines, stderr_output)
        elseif #response_lines > 0 then
            vim.list_extend(display_lines, response_lines)
        elseif not is_running then
            table.insert(display_lines, "No response received.")
            append_stderr_block(display_lines, stderr_output)
        end

        vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)

        -- Auto-scroll to bottom if window is valid
        local wins = vim.fn.win_findbuf(buf)
        if #wins > 0 then
            local line_count = vim.api.nvim_buf_line_count(buf)
            pcall(vim.api.nvim_win_set_cursor, wins[1], { line_count, 0 })
        end
    end

    -- Start periodic display updates for spinner
    local function start_update_timer()
        update_timer = vim.fn.timer_start(SPINNER_INTERVAL_MS, function()
            vim.schedule(function()
                if is_running then
                    update_display()
                    start_update_timer()
                end
            end)
        end)
    end

    local function handle_timeout()
        vim.schedule(function()
            is_running = false
            if update_timer then
                vim.fn.timer_stop(update_timer)
                update_timer = nil
            end
            if system_obj then
                system_obj:kill(9)
            end
            if vim.api.nvim_buf_is_valid(buf) then
                local display_lines = vim.deepcopy(full_header)
                table.insert(display_lines, "**Error:** Request timed out after " .. math.floor(user_config.timeout_ms / 1000) .. " seconds")
                append_stderr_block(display_lines, stderr_output)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                -- Save session even on timeout (only if we have a session ID)
                if current_session_id then
                    save_session(current_session_id, table.concat(display_lines, "\n"))
                end
            end
        end)
    end

    local function execute()
        -- Start run timer
        run_start_time = vim.loop.now()

        -- Only start timeout timer if timeout_ms is not -1
        if user_config.timeout_ms ~= -1 then
            vim.fn.timer_start(user_config.timeout_ms, function()
                if is_running then
                    handle_timeout()
                end
            end)
        end

        -- Use streaming stdout handler
        system_obj = vim.system(cmd, {
            cwd = get_cwd(),
            stdout = function(err, data)
                if data then
                    vim.schedule(function()
                        -- Parse incoming data line by line
                        for line in data:gmatch("[^\r\n]+") do
                            table.insert(json_lines, line)
                        end
                        update_display()
                    end)
                end
            end,
            stderr = function(err, data)
                if data then
                    vim.schedule(function()
                        for line in data:gmatch("[^\r\n]+") do
                            table.insert(stderr_output, line)
                        end
                    end)
                end
            end,
        }, function(result)
            vim.schedule(function()
                is_running = false
                if update_timer then
                    vim.fn.timer_stop(update_timer)
                    update_timer = nil
                end

                -- Unregister the request
                if request_id then
                    unregister_request(request_id)
                end

                -- Final update
                local response_lines, err, _, _, _, final_cli_session_id = parse_streaming_response(json_lines)
                local display_lines = vim.deepcopy(full_header)

                -- Ensure we have the CLI session ID for saving
                if final_cli_session_id and not current_session_id then
                    current_session_id = final_cli_session_id
                    vim.b[buf].opencode_session_id = current_session_id
                end

                if err then
                    table.insert(display_lines, "**Error:** " .. err)
                    append_stderr_block(display_lines, stderr_output)
                elseif #response_lines == 0 then
                    if result.code ~= 0 then
                        table.insert(display_lines, "**Error:** opencode exited with code " .. result.code)
                        append_stderr_block(display_lines, stderr_output)
                    else
                        table.insert(display_lines, "No response received.")
                        append_stderr_block(display_lines, stderr_output)
                    end
                else
                    vim.list_extend(display_lines, response_lines)
                end

                -- Update buffer if still valid
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                end

                -- Save session to file (only if we have a CLI session ID)
                if current_session_id then
                    save_session(current_session_id, table.concat(display_lines, "\n"))
                end
            end)
        end)

        -- Register request for cancellation tracking
        local cleanup_fn = function()
            is_running = false
            if update_timer then
                vim.fn.timer_stop(update_timer)
                update_timer = nil
            end
        end
        request_id = register_request(system_obj, cleanup_fn)

        -- Set up autocmd to kill process if buffer is deleted
        vim.api.nvim_create_autocmd("BufDelete", {
            buffer = buf,
            once = true,
            callback = function()
                if system_obj and is_running then
                    pcall(function() system_obj:kill(9) end)
                end
                if update_timer then
                    vim.fn.timer_stop(update_timer)
                end
                if request_id then
                    unregister_request(request_id)
                end
            end,
        })
    end

    -- Start spinner and execute immediately
    update_display()
    start_update_timer()
    execute()
end

-- =============================================================================
-- Run OpenCode Command (slash commands)
-- =============================================================================

local function run_opencode_command(command, args)
    -- Clear session for new command (session ID will be set when we get it from CLI)
    current_session_id = nil
    current_session_name = nil

    local buf, _ = create_response_split("OpenCode Response", true)

    -- Extract file references from args if present
    local files = {}
    if args and args ~= "" then
        files = extract_file_references(args)
    end

    -- Build command
    local base_cmd = { "opencode", "run", "--agent", "build", "--format", "json", "--command", command }
    local cmd = build_opencode_cmd(base_cmd, (args and args ~= "") and args or nil, files)

    -- Build header
    local model_info = selected_model and (" [" .. get_model_display() .. "]") or ""
    local args_display = (args and args ~= "") and (" " .. args) or ""
    local cmd_display = table.concat(cmd, " ")
    local header_lines = {
        "**Command:** `" .. cmd_display .. "`",
        "",
        "**Running:** `/" .. command .. "`" .. args_display .. model_info,
        "",
        "---",
        "",
    }

    -- State for streaming updates
    local json_lines = {}
    local stderr_output = {}
    local system_obj = nil
    local is_running = true
    local run_start_time = vim.loop.now()
    local spinner_idx = 1
    local update_timer = nil
    local request_id = nil

    -- Function to update display with current streaming state
    local function update_display()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end

        local display_lines = vim.deepcopy(header_lines)

        -- Add spinner
        local spinner_char = SPINNER_FRAMES[spinner_idx]
        spinner_idx = (spinner_idx % #SPINNER_FRAMES) + 1

        local response_lines, err, is_thinking, current_tool, tool_status, new_cli_session_id = parse_streaming_response(json_lines)

        -- Capture CLI session ID if we don't have one yet
        if new_cli_session_id and not current_session_id then
            current_session_id = new_cli_session_id
            vim.b[buf].opencode_session_id = current_session_id
        end

        if is_running then
            -- Build status line with elapsed time
            local elapsed = ""
            if run_start_time then
                local seconds = math.floor((vim.loop.now() - run_start_time) / 1000)
                elapsed = " (" .. seconds .. "s)"
            end
            local status_text

            if is_thinking then
                status_text = "**Status:** Thinking" .. elapsed .. " " .. spinner_char
            elseif current_tool then
                if tool_status == "calling" then
                    status_text = "**Status:** Executing `" .. current_tool .. "`" .. elapsed .. " " .. spinner_char
                else
                    status_text = "**Status:** Completed `" .. current_tool .. "`" .. elapsed .. " " .. spinner_char
                end
            else
                status_text = "**Status:** Running" .. elapsed .. " " .. spinner_char
            end

            table.insert(display_lines, status_text)
            table.insert(display_lines, "")
        end

        if err then
            table.insert(display_lines, "**Error:** " .. err)
            append_stderr_block(display_lines, stderr_output)
        elseif #response_lines > 0 then
            vim.list_extend(display_lines, response_lines)
        elseif not is_running then
            table.insert(display_lines, "No response received.")
            append_stderr_block(display_lines, stderr_output)
        end

        vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)

        -- Auto-scroll to bottom if window is valid
        local wins = vim.fn.win_findbuf(buf)
        if #wins > 0 then
            local line_count = vim.api.nvim_buf_line_count(buf)
            pcall(vim.api.nvim_win_set_cursor, wins[1], { line_count, 0 })
        end
    end

    -- Start periodic display updates for spinner
    local function start_update_timer()
        update_timer = vim.fn.timer_start(SPINNER_INTERVAL_MS, function()
            vim.schedule(function()
                if is_running then
                    update_display()
                    start_update_timer()
                end
            end)
        end)
    end

    local function handle_timeout()
        vim.schedule(function()
            is_running = false
            if update_timer then
                vim.fn.timer_stop(update_timer)
                update_timer = nil
            end
            if system_obj then
                system_obj:kill(9)
            end
            if vim.api.nvim_buf_is_valid(buf) then
                local display_lines = vim.deepcopy(header_lines)
                table.insert(display_lines, "**Error:** Request timed out after " .. math.floor(user_config.timeout_ms / 1000) .. " seconds")
                append_stderr_block(display_lines, stderr_output)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                if current_session_id then
                    save_session(current_session_id, table.concat(display_lines, "\n"))
                end
            end
        end)
    end

    -- Start timeout timer only if timeout_ms is not -1
    if user_config.timeout_ms ~= -1 then
        vim.fn.timer_start(user_config.timeout_ms, function()
            if is_running then
                handle_timeout()
            end
        end)
    end

    -- Start spinner
    update_display()
    start_update_timer()

    -- Use streaming stdout handler
    system_obj = vim.system(cmd, {
        cwd = get_cwd(),
        stdout = function(_, data)
            if data then
                vim.schedule(function()
                    for line in data:gmatch("[^\r\n]+") do
                        table.insert(json_lines, line)
                    end
                    update_display()
                end)
            end
        end,
        stderr = function(_, data)
            if data then
                vim.schedule(function()
                    for line in data:gmatch("[^\r\n]+") do
                        table.insert(stderr_output, line)
                    end
                end)
            end
        end,
    }, function(result)
        vim.schedule(function()
            is_running = false
            if update_timer then
                vim.fn.timer_stop(update_timer)
                update_timer = nil
            end

            -- Unregister the request
            if request_id then
                unregister_request(request_id)
            end

            -- Final update
            local response_lines, err, _, _, _, final_cli_session_id = parse_streaming_response(json_lines)
            local display_lines = vim.deepcopy(header_lines)

            -- Ensure we have the CLI session ID for saving
            if final_cli_session_id and not current_session_id then
                current_session_id = final_cli_session_id
                vim.b[buf].opencode_session_id = current_session_id
            end

            if err then
                table.insert(display_lines, "**Error:** " .. err)
                append_stderr_block(display_lines, stderr_output)
            elseif #response_lines == 0 then
                if result.code ~= 0 then
                    table.insert(display_lines, "**Error:** opencode exited with code " .. result.code)
                    append_stderr_block(display_lines, stderr_output)
                else
                    table.insert(display_lines, "Command completed successfully.")
                    append_stderr_block(display_lines, stderr_output)
                end
            else
                vim.list_extend(display_lines, response_lines)
            end

            -- Update buffer if still valid
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
            end

            -- Save session (only if we have a CLI session ID)
            if current_session_id then
                save_session(current_session_id, table.concat(display_lines, "\n"))
            end
        end)
    end)

    -- Register request for cancellation tracking
    local cleanup_fn = function()
        is_running = false
        if update_timer then
            vim.fn.timer_stop(update_timer)
            update_timer = nil
        end
    end
    request_id = register_request(system_obj, cleanup_fn)

    -- Set up autocmd to kill process if buffer is deleted
    vim.api.nvim_create_autocmd("BufDelete", {
        buffer = buf,
        once = true,
        callback = function()
            if system_obj and is_running then
                pcall(function() system_obj:kill(9) end)
            end
            if update_timer then
                vim.fn.timer_stop(update_timer)
            end
            if request_id then
                unregister_request(request_id)
            end
        end,
    })
end

-- =============================================================================
-- Prompt Window
-- =============================================================================

--- Get session display name for title
---@return string
local function get_session_display()
    if current_session_name then
        local display = current_session_name:sub(1, 20)
        if #current_session_name > 20 then
            display = display .. "..."
        end
        return display
    elseif current_session_id then
        return "Session: " .. current_session_id:sub(1, 15)
    end
    return "New"
end

local function get_window_title(content, show_session)
    local mode = (content and content:match("#plan")) and "plan" or "build"
    local title = " OpenCode [" .. mode .. "] [" .. get_model_display() .. "]"
    if show_session and current_session_id then
        title = title .. " [" .. get_session_display() .. "]"
    end
    return title .. " "
end

local function get_source_file()
    local bufname = vim.fn.expand("%")
    local buftype = vim.bo.buftype
    local filetype = vim.bo.filetype

    if bufname == "" or buftype ~= "" or filetype == "netrw" or filetype == "oil" then
        return nil
    end
    if vim.fn.filereadable(bufname) == 0 then
        return nil
    end

    -- Convert to path relative to cwd
    local full_path = vim.fn.fnamemodify(bufname, ":p")
    local cwd = get_cwd()
    if not cwd:match("/$") then
        cwd = cwd .. "/"
    end

    -- If the file is under cwd, return relative path
    if full_path:sub(1, #cwd) == cwd then
        return full_path:sub(#cwd + 1)
    end

    -- Otherwise return the original bufname (could be relative already)
    return bufname
end

-- Forward declaration for session picker
local select_session_for_prompt

--- Check if content contains a session reference
---@param content string
---@return boolean
local function has_session_reference(content)
    return content:match("#session%(([^)]+)%)") ~= nil
end

--- Get session id from response buffer if current buffer is one
---@return string|nil
local function get_session_from_current_buffer()
    local current_buf = vim.api.nvim_get_current_buf()
    if current_buf == response_buf and vim.api.nvim_buf_is_valid(response_buf) then
        return vim.b[response_buf].opencode_session_id
    end
    return nil
end

--- Open the main prompt window
---@param initial_prompt? table Initial prompt lines (from visual selection)
---@param filetype? string Filetype for code fence
---@param source_file? string Source file path
---@param session_id_to_continue? string Session ID to continue (from picker or response buffer)
M.OpenCode = function(initial_prompt, filetype, source_file, session_id_to_continue)
    -- Check if we're opening from a response buffer - get its session id
    local from_response_session = get_session_from_current_buffer()
    local session_to_use = session_id_to_continue or from_response_session

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

    -- Clear session state (we'll use #session(<id>) in the prompt instead)
    clear_session()

    local buf, win = create_floating_window({
        width = user_config.prompt_window.width,
        height = user_config.prompt_window.height,
        title = get_window_title(nil, session_to_use ~= nil),
        filetype = "opencode",
        name = "OpenCode Prompt",
    })

    vim.b[buf].opencode_source_file = source_file

    -- Setup initial content
    if initial_prompt then
        draft_content = nil
        draft_cursor = nil
        local initial_lines = {}
        -- Add session reference if continuing a session
        if session_to_use then
            table.insert(initial_lines, "#session(" .. session_to_use .. ")")
        end
        -- Add #buffer reference if we have a source file
        if source_file and source_file ~= "" then
            table.insert(initial_lines, "#buffer")
        end
        table.insert(initial_lines, "```" .. filetype)
        vim.list_extend(initial_lines, initial_prompt)
        vim.list_extend(initial_lines, { "```", "" })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
        vim.api.nvim_win_set_cursor(win, { #initial_lines, 0 })
    elseif draft_content then
        -- If we have draft content but need to add session reference
        local lines_to_set = vim.deepcopy(draft_content)
        if session_to_use and not has_session_reference(table.concat(lines_to_set, "\n")) then
            table.insert(lines_to_set, 1, "#session(" .. session_to_use .. ")")
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines_to_set)
        if draft_cursor then
            -- Adjust cursor if we inserted a session line
            local row_offset = (session_to_use and not has_session_reference(table.concat(draft_content, "\n"))) and 1 or
                0
            pcall(vim.api.nvim_win_set_cursor, win, { draft_cursor[1] + row_offset, draft_cursor[2] })
        end
    elseif session_to_use then
        -- No draft, but we need to add session reference
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#session(" .. session_to_use .. ")", "" })
        vim.api.nvim_win_set_cursor(win, { 2, 0 })
    end

    vim.cmd("startinsert")

    -- Update title on content change and handle #session trigger
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = buf,
        callback = function()
            if not vim.api.nvim_win_is_valid(win) then
                return
            end

            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local content = table.concat(lines, "\n")

            -- Check for #session trigger (without parentheses - user wants to pick a session)
            if content:match("#session%s*$") or content:match("#session[%s\n]") then
                -- But not if it already has session id: #session(...)
                if not content:match("#session%(") then
                    -- Remove #session from content
                    local new_lines = {}
                    for _, line in ipairs(lines) do
                        local new_line = line:gsub("#session%s*$", ""):gsub("#session([%s\n])", "%1")
                        table.insert(new_lines, new_line)
                    end
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)

                    -- Save current draft
                    local cursor_pos = vim.api.nvim_win_get_cursor(win)
                    draft_content = new_lines
                    draft_cursor = cursor_pos

                    -- Close prompt window and open session picker
                    vim.api.nvim_win_close(win, true)
                    select_session_for_prompt(source_file)
                    return
                end
            end

            -- Update title - show session info if content has #session(<id>)
            local has_session = has_session_reference(content)
            vim.api.nvim_win_set_config(win, {
                title = get_window_title(content, has_session),
                title_pos = "center",
            })
        end,
    })

    local function submit_prompt()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local content = table.concat(lines, "\n")

        -- Collect files to attach via --file flag
        local files_to_attach = {}

        -- If source_file is referenced via #buffer or #buf, add it to files
        if source_file and source_file ~= "" then
            if content:match("#buffer") or content:match("#buf") then
                table.insert(files_to_attach, source_file)
            end
            -- Replace #buffer/#buf with @filepath reference in the prompt text
            content = content:gsub("#buffer", "@" .. source_file):gsub("#buf", "@" .. source_file)
        end

        -- Remove bare #session triggers (but keep #session(<id>))
        content = content:gsub("#session%s*$", ""):gsub("#session([%s\n])", "%1")

        draft_content = nil
        draft_cursor = nil
        vim.api.nvim_win_close(win, true)

        if content and vim.trim(content) ~= "" then
            run_opencode(content, files_to_attach, source_file)
        end
    end

    local function save_draft_and_close()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local has_content = vim.iter(lines):any(function(line)
            return line ~= ""
        end)

        if has_content then
            draft_content = lines
            draft_cursor = vim.api.nvim_win_get_cursor(win)
        else
            draft_content = nil
            draft_cursor = nil
        end
        vim.api.nvim_win_close(win, true)
    end

    -- Keymaps
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = submit_prompt,
    })

    -- Handle :wq and :x by using abbreviations that expand to :w
    vim.cmd(string.format("cnoreabbrev <buffer> wq w"))
    vim.cmd(string.format("cnoreabbrev <buffer> x w"))

    vim.keymap.set("n", "q", save_draft_and_close, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "<Esc>", save_draft_and_close, { buffer = buf, noremap = true, silent = true })
end

-- =============================================================================
-- Review Window
-- =============================================================================

M.OpenCodeReview = function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

    local buf, win = create_floating_window({
        width = user_config.review_window.width,
        height = user_config.review_window.height,
        title = " OpenCode Review [" .. get_model_display() .. "] ",
        filetype = "opencode",
        name = "OpenCode Review",
    })

    local help_lines = {
        "# Review target (leave empty for default):",
        "# Examples:",
        "#   HEAD~3        - last 3 commits",
        "#   abc123        - specific commit",
        "#   main..HEAD    - commits since main",
        "#   v1.0.0        - specific tag",
        "",
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, help_lines)
    vim.api.nvim_win_set_cursor(win, { #help_lines, 0 })

    vim.cmd("startinsert")

    local function submit_review()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local input_lines = vim.iter(lines):filter(function(line)
            return not line:match("^#")
        end):totable()
        local args = vim.trim(table.concat(input_lines, " "))
        vim.api.nvim_win_close(win, true)
        run_opencode_command("review", args)
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = submit_review,
    })

    -- Handle :wq and :x by using abbreviations that expand to :w
    vim.cmd(string.format("cnoreabbrev <buffer> wq w"))
    vim.cmd(string.format("cnoreabbrev <buffer> x w"))

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, noremap = true, silent = true })

    vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, noremap = true, silent = true })
end

-- =============================================================================
-- Model Selection
-- =============================================================================

M.SelectModel = function()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    -- Get models list synchronously
    local result = vim.system({ "opencode", "models" }, { text = true }):wait()
    local models = { "(default - no model specified)" }

    if result.stdout then
        for line in result.stdout:gmatch("[^\r\n]+") do
            if line ~= "" then
                table.insert(models, line)
            end
        end
    end

    pickers.new({}, {
        prompt_title = "Select OpenCode Model",
        finder = finders.new_table({ results = models }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local model = selection[1]
                    selected_model = (model == "(default - no model specified)") and nil or model
                    save_config()
                    vim.notify("OpenCode model set to: " .. get_model_display(), vim.log.levels.INFO)
                end
            end)
            return true
        end,
    }):find()
end

-- =============================================================================
-- Session Selection
-- =============================================================================

--- Open session picker for viewing/continuing sessions
---@param callback? function Optional callback(session_id, session_name) after selection
---@param for_append? boolean If true, selected session will be used for appending
local function open_session_picker(callback, for_append)
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local sessions = list_sessions()

    -- Create entries with "New Session" at the top
    local entries = { { id = nil, display = NEW_SESSION_LABEL, name = nil } }
    for _, session in ipairs(sessions) do
        table.insert(entries, session)
    end

    pickers.new({}, {
        prompt_title = for_append and "Select Session to Continue" or "OpenCode Sessions",
        finder = finders.new_table({
            results = entries,
            entry_maker = function(entry)
                return {
                    value = entry,
                    display = entry.display,
                    ordinal = entry.display,
                }
            end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local entry = selection.value
                    if callback then
                        callback(entry.id, entry.name)
                    else
                        -- Default behavior: load session into response buffer
                        if entry.id then
                            -- Load existing session
                            current_session_id = entry.id
                            current_session_name = entry.name
                            local content = load_session(entry.id)
                            if content then
                                local buf, _ = create_response_split("OpenCode Response", true)
                                vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
                                vim.notify("Loaded session: " .. (entry.name or entry.id), vim.log.levels.INFO)
                            end
                        else
                            -- New session selected
                            clear_session()
                            start_new_session()
                            vim.notify("Started new session", vim.log.levels.INFO)
                        end
                    end
                end
            end)
            return true
        end,
    }):find()
end

--- Session picker specifically for prompt window (#session trigger)
---@param source_file? string Source file for the prompt
select_session_for_prompt = function(source_file)
    open_session_picker(function(session_id, session_name)
        if session_id then
            -- User selected an existing session - load it and open prompt with session reference
            local content = load_session(session_id)
            if content then
                -- Set current session so the response buffer gets the right id
                current_session_id = session_id
                current_session_name = session_name
                local buf, _ = create_response_split("OpenCode Response", true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
                vim.b[buf].opencode_session_id = session_id
            end
            -- Reopen prompt window with session id (will be inserted as #session(<id>))
            M.OpenCode(nil, nil, source_file, session_id)
        else
            -- User wants a new session - just reopen prompt without session reference
            M.OpenCode(nil, nil, source_file, nil)
        end
    end, true)
end

--- Public function to select sessions
M.SelectSession = function()
    open_session_picker()
end

--- Toggle the response buffer (OpenCodeCLI)
M.ToggleCLI = function()
    toggle_response_buffer()
end

--- Initialize opencode project (runs init command)
M.Init = function()
    run_opencode_command("init", nil)
end

--- Stop all active requests
M.StopAll = function()
    local count = cancel_all_requests()
    if count > 0 then
        vim.notify("Stopped " .. count .. " active request(s)", vim.log.levels.INFO)
    else
        vim.notify("No active requests to stop", vim.log.levels.INFO)
    end
end

--- Get the number of active requests
---@return number
M.GetActiveRequestCount = function()
    return get_active_request_count()
end

-- =============================================================================
-- Commands & Keymaps
-- =============================================================================

local function setup_commands()
    -- Main command (OpenCode / OC)
    vim.api.nvim_create_user_command("OpenCode", function()
        M.OpenCode(nil, nil, get_source_file())
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OC", function()
        M.OpenCode(nil, nil, get_source_file())
    end, { nargs = 0 })

    -- With selection
    vim.api.nvim_create_user_command("OpenCodeWSelection", function()
        local source_file = get_source_file()
        local mode = vim.fn.mode()

        if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
            M.OpenCode(nil, nil, source_file)
            return
        end

        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local selection_lines = vim.fn.getregion(start_pos, end_pos, { type = mode })
        M.OpenCode(selection_lines, vim.bo.filetype, source_file)
    end, { nargs = 0 })

    -- Model selection
    vim.api.nvim_create_user_command("OpenCodeModel", function()
        M.SelectModel()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCModel", function()
        M.SelectModel()
    end, { nargs = 0 })

    -- Review
    vim.api.nvim_create_user_command("OpenCodeReview", function()
        M.OpenCodeReview()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCReview", function()
        M.OpenCodeReview()
    end, { nargs = 0 })

    -- CLI toggle
    vim.api.nvim_create_user_command("OpenCodeCLI", function()
        M.ToggleCLI()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCCLI", function()
        M.ToggleCLI()
    end, { nargs = 0 })

    -- Sessions
    vim.api.nvim_create_user_command("OpenCodeSessions", function()
        M.SelectSession()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCSessions", function()
        M.SelectSession()
    end, { nargs = 0 })

    -- Init (runs /init command)
    vim.api.nvim_create_user_command("OpenCodeInit", function()
        M.Init()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCInit", function()
        M.Init()
    end, { nargs = 0 })

    -- Stop all active requests
    vim.api.nvim_create_user_command("OpenCodeStop", function()
        M.StopAll()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCStop", function()
        M.StopAll()
    end, { nargs = 0 })
end

local function setup_keymaps()
    if not user_config.keymaps.enable_default then
        return
    end

    local keymap = user_config.keymaps.open_prompt
    vim.keymap.set("n", keymap, "<Cmd>OpenCode<CR>", { noremap = true, silent = true, desc = "Open OpenCode prompt" })
    vim.keymap.set("v", keymap, "<Cmd>OpenCodeWSelection<CR>",
        { noremap = true, silent = true, desc = "Open OpenCode with selection" })
end

-- =============================================================================
-- Setup
-- =============================================================================

--- Setup auto-reload for buffers when files change on disk
local function setup_auto_reload()
    -- Enable autoread globally
    vim.o.autoread = true

    -- Create autocommands for detecting file changes
    local augroup = vim.api.nvim_create_augroup("OpenCodeAutoReload", { clear = true })

    -- Check for file changes when entering a buffer or window
    vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
        group = augroup,
        pattern = "*",
        callback = function()
            if vim.fn.getcmdwintype() == "" then
                vim.cmd("checktime")
            end
        end,
    })

    -- Notify when file changes are detected and reloaded
    vim.api.nvim_create_autocmd("FileChangedShellPost", {
        group = augroup,
        pattern = "*",
        callback = function()
            vim.notify("File changed on disk. Buffer reloaded.", vim.log.levels.INFO)
        end,
    })
end

--- Setup the opencode plugin
---@param opts? table User configuration options
function M.setup(opts)
    if is_initialized then
        return
    end

    -- Merge user config with defaults
    if opts then
        user_config = vim.tbl_deep_extend("force", default_config, opts)
    end

    -- Initialize commands and keymaps
    setup_commands()
    setup_keymaps()
    setup_auto_reload()

    -- Clean up active requests when Vim exits
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            local count = cancel_all_requests()
            if count > 0 then
                -- Brief message - Vim is exiting anyway
                print("OpenCode: Stopped " .. count .. " active request(s)")
            end
        end,
    })

    is_initialized = true
end

return M
