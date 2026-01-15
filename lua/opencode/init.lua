local M = {}

-- =============================================================================
-- Constants
-- =============================================================================

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local TIMEOUT_MS = 120000 -- 2 minutes
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
    -- Keymaps
    keymaps = {
        enable_default = true,
        open_prompt = "<leader>oc",
    },
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

--- Generate a unique session ID
---@return string
local function generate_session_id()
    return os.date("%Y%m%d_%H%M%S") .. "_" .. math.random(1000, 9999)
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

--- Start a new session
local function start_new_session()
    current_session_id = generate_session_id()
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

local function has_agents_md()
    return vim.fn.filereadable(get_cwd() .. "/AGENTS.md") == 1
end

local function init_opencode(callback)
    local cwd = get_cwd()
    vim.system({ "opencode", "agent", "create" }, { cwd = cwd }, function(result)
        if callback then
            vim.schedule(function()
                if result.code ~= 0 then
                    -- Log error for debugging
                    local stderr = result.stderr or ""
                    if stderr ~= "" then
                        vim.notify("opencode agent create failed: " .. stderr, vim.log.levels.WARN)
                    end
                end
                callback(result.code == 0, result.stderr)
            end)
        end
    end)
end

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
---@return table cmd Complete command
local function build_opencode_cmd(base_args, prompt)
    local cmd = vim.deepcopy(base_args)
    if selected_model and selected_model ~= "" then
        table.insert(cmd, "--model")
        table.insert(cmd, selected_model)
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

--- Parse streaming JSON output and return current state
---@param json_lines table Lines of JSON output received so far
---@return table response_lines Lines of response text
---@return string|nil error_message Error if any
---@return boolean is_thinking Whether model is currently thinking
---@return string|nil current_tool Current tool being executed (if any)
---@return string|nil tool_status Status of the tool execution
local function parse_streaming_response(json_lines)
    local response_lines = {}
    local error_message = nil
    local is_thinking = false
    local current_tool = nil
    local tool_status = nil

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
                elseif data.type == "tool-call" and data.part then
                    -- Tool is being called
                    is_thinking = false
                    current_tool = data.part.toolName or data.part.name or "unknown tool"
                    tool_status = "calling"
                elseif data.type == "tool-result" and data.part then
                    -- Tool finished
                    current_tool = data.part.toolName or data.part.name or "tool"
                    tool_status = "completed"
                end
            end
        end
    end

    return response_lines, error_message, is_thinking, current_tool, tool_status
end

--- Run opencode with session support
---@param prompt string The prompt to send
local function run_opencode(prompt)
    if not prompt or prompt == "" then
        return
    end

    -- Extract session id from prompt if present
    local session_id
    prompt, session_id = extract_session_from_prompt(prompt)

    -- Determine if this is a continuation of an existing session
    local is_continuation = session_id ~= nil

    -- Determine agent mode
    local agent = "build"
    if prompt:match("#plan") then
        agent = "plan"
        prompt = prompt:gsub("#plan%s*", ""):gsub("%s*#plan", "")
    end

    -- Set or create session
    if session_id then
        current_session_id = session_id
        current_session_name = nil -- Will be updated from loaded content
    elseif not current_session_id then
        start_new_session()
    end

    -- Get existing content if continuing
    local existing_content = {}
    if is_continuation then
        -- Load from file if we have a session id
        local saved_content = load_session(session_id)
        if saved_content then
            existing_content = vim.split(saved_content, "\n", { plain = true })
        elseif response_buf and vim.api.nvim_buf_is_valid(response_buf) then
            existing_content = vim.api.nvim_buf_get_lines(response_buf, 0, -1, false)
        end
    end

    local buf, _ = create_response_split("OpenCode Response", not is_continuation)

    -- Update buffer's session id
    vim.b[buf].opencode_session_id = current_session_id

    -- Build command
    local cmd = build_opencode_cmd(
        { "opencode", "run", "--agent", agent, "--format", "json" },
        prompt
    )

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
    local is_initializing = false
    local init_message = nil
    local init_start_time = nil
    local run_start_time = nil
    local spinner_idx = 1
    local update_timer = nil

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

        if is_initializing then
            local elapsed = ""
            if init_start_time then
                local seconds = math.floor((vim.loop.now() - init_start_time) / 1000)
                elapsed = " (" .. seconds .. "s)"
            end
            table.insert(display_lines, "**Status:** Initializing opencode" .. elapsed .. " " .. spinner_char)
            table.insert(display_lines, "")
            if init_message then
                table.insert(display_lines, init_message)
                table.insert(display_lines, "")
            end
            table.insert(display_lines, "_Creating AGENTS.md in your project directory..._")
            table.insert(display_lines, "_Running:_ `opencode agent create`")
            table.insert(display_lines, "")
            table.insert(display_lines, "This is a one-time setup that configures opencode for your project.")
            table.insert(display_lines, "It may take a moment on first run.")
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
            return
        end

        local response_lines, err, is_thinking, current_tool, tool_status = parse_streaming_response(json_lines)

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
                status_text = "**Status:** Running" .. model_info .. elapsed .. " " .. spinner_char
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
                local display_lines = vim.deepcopy(full_header)
                table.insert(display_lines, "**Error:** Request timed out after 120 seconds")
                append_stderr_block(display_lines, stderr_output)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                -- Save session even on timeout
                save_session(current_session_id, table.concat(display_lines, "\n"))
            end
        end)
    end

    local function execute()
        -- Clear initializing state and start run timer
        is_initializing = false
        run_start_time = vim.loop.now()

        vim.fn.timer_start(TIMEOUT_MS, function()
            if is_running then
                handle_timeout()
            end
        end)

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

                -- Final update
                local response_lines, err = parse_streaming_response(json_lines)
                local display_lines = vim.deepcopy(full_header)

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

                -- Always save session to file
                save_session(current_session_id, table.concat(display_lines, "\n"))
            end)
        end)
    end

    -- Check if we need to init first
    if not has_agents_md() then
        -- Set initializing state and start spinner
        is_initializing = true
        init_start_time = vim.loop.now()
        update_display()
        start_update_timer()

        init_opencode(function(success, stderr)
            if success then
                execute()
            else
                is_running = false
                is_initializing = false
                if update_timer then
                    vim.fn.timer_stop(update_timer)
                    update_timer = nil
                end
                if vim.api.nvim_buf_is_valid(buf) then
                    local display_lines = vim.deepcopy(full_header)
                    table.insert(display_lines, "**Error:** Failed to initialize opencode")
                    if stderr and stderr ~= "" then
                        table.insert(display_lines, "")
                        table.insert(display_lines, "```")
                        table.insert(display_lines, stderr)
                        table.insert(display_lines, "```")
                    end
                    table.insert(display_lines, "")
                    table.insert(display_lines, "Make sure the `opencode` CLI is installed and in your PATH.")
                    table.insert(display_lines, "Try running `opencode agent create` manually in your project directory.")
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                end
            end
        end)
    else
        -- Start spinner and execute immediately
        update_display()
        start_update_timer()
        execute()
    end
end

-- =============================================================================
-- Run OpenCode Command (slash commands)
-- =============================================================================

local function run_opencode_command(command, args)
    -- Ensure we have a session for commands too
    if not current_session_id then
        start_new_session()
    end

    local buf, _ = create_response_split("OpenCode Response", true)

    -- Show loading message
    local model_info = selected_model and (" [" .. get_model_display() .. "]") or ""
    local args_display = (args and args ~= "") and (" " .. args) or ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "Running " .. command .. args_display .. model_info .. "...",
        "",
    })

    local function execute()
        local cmd = build_opencode_cmd(
            { "opencode", "run", "--command", command, "--format", "json" },
            (args and args ~= "") and args or nil
        )

        vim.system(cmd, { cwd = get_cwd() }, function(result)
            vim.schedule(function()
                local json_output = parse_lines(result.stdout)
                local response, err = parse_opencode_response(json_output)
                local display_lines = {}

                if err then
                    display_lines = { "Error: " .. err }
                elseif not response or response == "" then
                    if result.code ~= 0 then
                        display_lines = {
                            "Error: opencode exited with code " .. result.code,
                            "",
                            result.stderr or "",
                        }
                    else
                        display_lines = { "No response received." }
                    end
                else
                    display_lines = vim.split(response, "\n", { plain = true })
                end

                -- Update buffer if still valid
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                end

                -- Always save session
                save_session(current_session_id, table.concat(display_lines, "\n"))
            end)
        end)
    end

    if not has_agents_md() then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Initializing opencode...", "" })
        init_opencode(function(success)
            if success then
                execute()
            elseif vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    "Error: Failed to initialize opencode",
                })
            end
        end)
    else
        execute()
    end
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

        if source_file and source_file ~= "" then
            content = content:gsub("#buffer", "@" .. source_file):gsub("#buf", "@" .. source_file)
        end

        -- Remove bare #session triggers (but keep #session(<id>))
        content = content:gsub("#session%s*$", ""):gsub("#session([%s\n])", "%1")

        draft_content = nil
        draft_cursor = nil
        vim.api.nvim_win_close(win, true)

        if content and vim.trim(content) ~= "" then
            run_opencode(content)
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
        run_opencode_command("/review", args)
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

    is_initialized = true
end

return M
