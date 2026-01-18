local M = {}

-- =============================================================================
-- Response Module
-- =============================================================================
-- Response parsing for opencode.nvim

-- =============================================================================
-- Response Parsing
-- =============================================================================

--- Parse opencode JSON output and extract assistant text
---@param json_lines table Lines of JSON output
---@return string|nil response Response text or nil
---@return string|nil error Error message or nil
---@return boolean is_thinking Whether model is thinking
function M.parse_opencode_response(json_lines)
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

--- Parse streaming JSON output and return current state
---@param json_lines table Lines of JSON output received so far
---@return table response_lines Lines of response text
---@return string|nil error_message Error if any
---@return boolean is_thinking Whether model is currently thinking
---@return string|nil current_tool Current tool being executed (if any)
---@return string|nil tool_status Status of the tool execution
---@return string|nil cli_session_id The CLI session ID from opencode
---@return table|nil todos Current todo list (if any)
function M.parse_streaming_response(json_lines)
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
                    -- Split the text by newlines (handle both \n and \r\n) and add each line separately
                    -- First normalize \r\n to \n, then split
                    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
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

-- =============================================================================
-- SSE Event Parsing (for HTTP API mode)
-- =============================================================================

---@class SSEState
---@field response_text string Accumulated response text
---@field is_thinking boolean Whether model is currently thinking
---@field current_tool string|nil Current tool being executed
---@field tool_status string|nil Status of the tool execution
---@field session_id string|nil Current session ID
---@field message_id string|nil Current message ID
---@field todos table|nil Current todo list
---@field error_message string|nil Error message if any
---@field is_busy boolean Whether the session is busy
---@field last_text_part_id string|nil ID of the last text part (for full-text updates)

--- Create a new SSE state for tracking streaming responses
---@return SSEState
function M.create_sse_state()
    return {
        response_text = "",
        is_thinking = false,
        current_tool = nil,
        tool_status = nil,
        session_id = nil,
        message_id = nil,
        todos = nil,
        error_message = nil,
        is_busy = false,
        last_text_part_id = nil,
    }
end

--- Process an SSE event and update state
--- Based on opencode SDK event types:
--- - message.part.updated: Text, tool, reasoning parts (with optional delta)
--- - message.updated: Message metadata
--- - session.status: Busy/idle status
--- - session.error: Errors
--- - todo.updated: Todo list updates
---@param state SSEState State to update
---@param event_type string|nil Event type
---@param event_data table|nil Event data (properties field from SSE)
---@return boolean changed Whether state changed (for UI updates)
function M.process_sse_event(state, event_type, event_data)
    if not event_type or not event_data then
        return false
    end

    local changed = false

    if event_type == "message.part.updated" then
        local part = event_data.part
        local delta = event_data.delta

        if part then
            -- Capture session ID and message ID
            if part.sessionID and not state.session_id then
                state.session_id = part.sessionID
                changed = true
            end
            if part.messageID and not state.message_id then
                state.message_id = part.messageID
                changed = true
            end

            if part.type == "text" then
                state.is_thinking = false
                state.current_tool = nil

                if delta then
                    -- Incremental delta - append to response_text
                    state.response_text = state.response_text .. delta
                    state.last_text_part_id = part.id
                    changed = true
                elseif part.text and part.text ~= "" then
                    -- Full text - this could be a replacement or initial full text
                    -- If it's the same part ID, this is an update (replace)
                    -- If it's a new part ID, append it
                    if part.id == state.last_text_part_id then
                        -- Same part, likely a full replacement - but we already have delta text
                        -- In practice, servers usually send either deltas OR full text, not both
                        -- If we already have content, don't replace it
                        if state.response_text == "" then
                            state.response_text = part.text
                            changed = true
                        end
                    else
                        -- New part with full text (no delta) - append it
                        state.response_text = state.response_text .. part.text
                        state.last_text_part_id = part.id
                        changed = true
                    end
                end

            elseif part.type == "reasoning" then
                state.is_thinking = true
                state.current_tool = nil
                changed = true

            elseif part.type == "tool" then
                state.is_thinking = false
                state.current_tool = part.tool or "unknown tool"
                if part.state then
                    state.tool_status = part.state.status or "running"
                    -- Capture todo list from todowrite tool
                    if part.tool == "todowrite" and part.state.input and part.state.input.todos then
                        state.todos = part.state.input.todos
                    end
                end
                changed = true
            end
        end

    elseif event_type == "message.updated" then
        local info = event_data.info
        if info then
            if info.sessionID then
                state.session_id = info.sessionID
            end
            if info.id then
                state.message_id = info.id
            end
            -- Check for error in message
            if info.error then
                local err = info.error
                state.error_message = err.data and err.data.message
                    or err.message
                    or err.name
                    or "Unknown error"
            end
            changed = true
        end

    elseif event_type == "session.status" then
        local status = event_data.status
        if status then
            state.is_busy = (status.type == "busy")
            changed = true
        end

    elseif event_type == "session.idle" then
        state.is_busy = false
        changed = true

    elseif event_type == "session.error" then
        local err = event_data.error
        if err then
            state.error_message = err.data and err.data.message
                or err.message
                or err.name
                or "Unknown error"
            changed = true
        end

    elseif event_type == "todo.updated" then
        if event_data.todos then
            state.todos = event_data.todos
            changed = true
        end
    end

    return changed
end

--- Alias for process_sse_event for compatibility
---@param state SSEState State to update
---@param event_type string|nil Event type
---@param event_data table|nil Event data
---@return boolean changed Whether state changed
M.parse_sse_event = M.process_sse_event

--- Get response lines from SSE state
---@param state SSEState
---@return table response_lines Lines of response text
function M.get_sse_response_lines(state)
    if state.response_text == "" then
        return {}
    end
    -- Normalize newlines and split
    local text = state.response_text:gsub("\r\n", "\n"):gsub("\r", "\n")
    return vim.split(text, "\n", { plain = true })
end

return M
