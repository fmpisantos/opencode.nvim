local M = {}

-- =============================================================================
-- UI Module
-- =============================================================================
-- UI components for opencode.nvim: windows, buffers, and spinner

local config = require("opencode.config")
local session = require("opencode.session")

-- =============================================================================
-- Spinner Class
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
        table.insert(display_lines, self.prefix .. config.SPINNER_FRAMES[self.idx])
        table.insert(display_lines, "")
        vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, display_lines)

        self.idx = (self.idx % #config.SPINNER_FRAMES) + 1

        if self.is_running then
            self.timer = vim.fn.timer_start(config.SPINNER_INTERVAL_MS, function()
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

M.Spinner = Spinner

-- =============================================================================
-- Response Buffer Management
-- =============================================================================

--- Create or reuse a response buffer in a vertical split
---@param name string Buffer name
---@param clear boolean Whether to clear the buffer
---@return number buf Buffer handle
---@return number win Window handle
function M.create_response_split(name, clear)
    local state = config.state

    -- Reuse existing buffer if valid
    if state.response_buf and vim.api.nvim_buf_is_valid(state.response_buf) then
        -- Check if buffer is already displayed in a window
        local wins = vim.fn.win_findbuf(state.response_buf)
        if #wins > 0 then
            state.response_win = wins[1]
            vim.api.nvim_set_current_win(state.response_win)
        else
            -- Buffer exists but not displayed, open in split
            vim.cmd("vsplit")
            state.response_win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(state.response_win, state.response_buf)
        end

        -- Apply wrap setting to window
        vim.wo[state.response_win].wrap = state.user_config.response_buffer.wrap

        if clear then
            vim.api.nvim_buf_set_lines(state.response_buf, 0, -1, false, {})
        end

        return state.response_buf, state.response_win
    end

    -- Create new buffer
    state.response_buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("vsplit")
    state.response_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.response_win, state.response_buf)

    vim.bo[state.response_buf].buftype = "nofile"
    vim.bo[state.response_buf].bufhidden = "hide"
    vim.bo[state.response_buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(state.response_buf, name)
    -- Prevent 'No write since last change' for this response buffer
    local autocmd_group = vim.api.nvim_create_augroup("OpenCode_NoSave_" .. state.response_buf, { clear = true })
    vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave", "BufUnload", "VimLeavePre" }, {
        group = autocmd_group,
        buffer = state.response_buf,
        callback = function()
            vim.bo[state.response_buf].modified = false
        end,
    })


    -- Apply wrap setting to window
    vim.wo[state.response_win].wrap = state.user_config.response_buffer.wrap

    -- Store session id in buffer variable for reference
    vim.b[state.response_buf].opencode_session_id = state.current_session_id

    -- Keymap to close (hide) the buffer
    vim.keymap.set("n", "q", function()
        if state.response_win and vim.api.nvim_win_is_valid(state.response_win) then
            vim.api.nvim_win_close(state.response_win, false)
            state.response_win = nil
        end
    end, { buffer = state.response_buf, noremap = true, silent = true, desc = "Close OpenCode response" })

    return state.response_buf, state.response_win
end

--- Toggle the response buffer visibility
function M.toggle_response_buffer()
    local state = config.state

    if not state.response_buf or not vim.api.nvim_buf_is_valid(state.response_buf) then
        vim.notify("No OpenCode session active. Use <leader>oc to start one.", vim.log.levels.INFO)
        return
    end

    local wins = vim.fn.win_findbuf(state.response_buf)
    if #wins > 0 then
        -- Buffer is visible, close the window
        vim.api.nvim_win_close(wins[1], false)
        state.response_win = nil
    else
        -- Buffer is hidden, show it in a split
        vim.cmd("vsplit")
        state.response_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(state.response_win, state.response_buf)
        -- Apply wrap setting to window
        vim.wo[state.response_win].wrap = state.user_config.response_buffer.wrap
    end
end

-- =============================================================================
-- Floating Window Management
-- =============================================================================

--- Create a centered floating window
---@param opts { width: number, height: number, title: string, filetype: string, name: string }
---@return number buf Buffer handle
---@return number win Window handle
function M.create_floating_window(opts)
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

--- Get window title for prompt window
---@param content? string Content to check for mode tags
---@param session_id? string Session ID to display (if provided, session info will be shown)
---@return string title
function M.get_window_title(content, session_id)
    local agent_mode = config.state.current_agent or "build"
    local project_mode = config.get_project_mode()
    
    -- If session ID is provided, try to load its settings
    if session_id then
        local settings = session.get_session_settings(session_id)
        -- Apply session settings or fall back to defaults (matching init.lua logic)
        project_mode = settings.mode or config.state.user_config.mode or "quick"
        if settings.agent then agent_mode = settings.agent end
    end

    if content then
        -- Check for explicit tags first (overrides session settings)
        if content:match("#plan") then agent_mode = "plan" end
        if content:match("#agentic") then project_mode = "agentic" end
        if content:match("#quick") then project_mode = "quick" end

        -- Simulate the iterative parsing of bare keywords to update the preview title correctly
        local temp_content = content
        local found = true
        while found do
            found = false
            if temp_content:match("^plan%s") or temp_content:match("^plan$") then
                agent_mode = "plan"
                temp_content = temp_content:gsub("^plan%s*", "")
                found = true
            elseif temp_content:match("^build%s") or temp_content:match("^build$") then
                agent_mode = "build"
                temp_content = temp_content:gsub("^build%s*", "")
                found = true
            end
            
            if not found then
                if temp_content:match("^agentic%s") or temp_content:match("^agentic$") then
                    project_mode = "agentic"
                    temp_content = temp_content:gsub("^agentic%s*", "")
                    found = true
                elseif temp_content:match("^quick%s") or temp_content:match("^quick$") then
                    project_mode = "quick"
                    temp_content = temp_content:gsub("^quick%s*", "")
                    found = true
                end
            end
        end
    end

    local title = " OpenCode [" .. agent_mode .. "] [" .. project_mode .. "] [" .. config.get_model_display() .. "]"
    if session_id then
        -- Use the passed session_id to display session info
        local display = #session_id > 8 and session_id:sub(1, 8) .. "..." or session_id
        title = title .. " [" .. display .. "]"
    end
    return title .. " "
end

-- =============================================================================
-- Auto-reload Setup
-- =============================================================================

--- Setup auto-reload for buffers when files change on disk
function M.setup_auto_reload()
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

return M
