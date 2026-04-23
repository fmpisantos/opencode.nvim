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
    local question = nil
    local options = nil

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
                        -- Capture questions and options
                        if state.input and (state.input.question or state.input.options) then
                            question = state.input.question
                            options = state.input.options
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

    return response_lines, error_message, is_thinking, current_tool, tool_status, cli_session_id, todos, question, options
end

-- =============================================================================
-- SSE Event Parsing (for HTTP API mode)
-- =============================================================================

---@class SSEState
---@field response_text string Accumulated response text (rebuilt from text_parts)
---@field text_parts table Ordered list of { id, text } entries for text parts
---@field text_parts_index table Map from part id to index in text_parts
---@field is_thinking boolean Whether model is currently thinking
---@field current_tool string|nil Current tool being executed
---@field tool_status string|nil Status of the tool execution
---@field session_id string|nil Current session ID
---@field message_id string|nil Current message ID
---@field todos table|nil Current todo list
---@field question string|nil Current question for user (legacy tool-embedded)
---@field options table|nil Current options for user (legacy tool-embedded)
---@field pending_permission table|nil Active opencode permission request (PermissionRequest)
---@field pending_question table|nil Active opencode question request (QuestionRequest)
---@field error_message string|nil Error message if any
---@field is_busy boolean Whether the session is busy

--- Create a new SSE state for tracking streaming responses
---@return SSEState
function M.create_sse_state()
    return {
        response_text = "",
        text_parts = {},
        text_parts_index = {},
        is_thinking = false,
        current_tool = nil,
        tool_status = nil,
        session_id = nil,
        message_id = nil,
        todos = nil,
        question = nil,
        options = nil,
        pending_permission = nil,
        pending_question = nil,
        error_message = nil,
        is_busy = false,
    }
end

--- Rebuild response_text from the ordered text parts
---@param state SSEState
local function rebuild_response_text(state)
    local buf = {}
    for _, p in ipairs(state.text_parts) do
        buf[#buf + 1] = p.text
    end
    state.response_text = table.concat(buf)
end

--- Update (append delta or replace full text) a text part and rebuild response_text
---@param state SSEState
---@param part_id string
---@param delta string|nil
---@param full_text string|nil
---@return boolean changed
local function upsert_text_part(state, part_id, delta, full_text)
    if not part_id then
        -- No id to track — fall back to accumulating onto a synthetic trailing part
        part_id = "__notrack__"
    end

    local idx = state.text_parts_index[part_id]
    local changed = false

    if delta and delta ~= "" then
        if idx then
            state.text_parts[idx].text = state.text_parts[idx].text .. delta
        else
            table.insert(state.text_parts, { id = part_id, text = delta })
            state.text_parts_index[part_id] = #state.text_parts
        end
        changed = true
    elseif full_text and full_text ~= "" then
        if idx then
            if state.text_parts[idx].text ~= full_text then
                state.text_parts[idx].text = full_text
                changed = true
            end
        else
            table.insert(state.text_parts, { id = part_id, text = full_text })
            state.text_parts_index[part_id] = #state.text_parts
            changed = true
        end
    end

    if changed then
        rebuild_response_text(state)
    end
    return changed
end

--- Process an SSE event and update state
--- Based on opencode SDK event types:
--- - message.part.updated: Text, tool, reasoning parts (with optional delta)
--- - message.updated: Message metadata
--- - session.status: Busy/idle status
--- - session.error: Errors
--- - todo.updated: Todo list updates
---@param state SSEState State to update
---@param event_type string|nil Event type (from SSE or top-level JSON)
---@param event_data table|nil Event data (properties field from SSE)
---@return boolean changed Whether state changed (for UI updates)
function M.process_sse_event(state, event_type, event_data)
    -- Try to extract event_type from event_data if not provided at top level
    -- OpenCode may send the type inside the properties/data object
    if not event_type and event_data and type(event_data) == "table" then
        event_type = event_data.type
    end

    if not event_type or not event_data then
        return false
    end

    local changed = false

    if event_type == "message.part.updated" then
        local part = event_data.part
        local delta = event_data.delta

        -- Ignore user message parts (echoed back by server)
        if event_data.role == "user" or (part and part.role == "user") then
            return false
        end

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

                if upsert_text_part(state, part.id, delta, part.text) then
                    changed = true
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
                    -- Capture questions and options
                    if part.state.input and (part.state.input.question or part.state.input.options) then
                        state.question = part.state.input.question
                        state.options = part.state.input.options
                    end
                end
                changed = true
            end
        end

    elseif event_type == "message.updated" then
        local info = event_data.info
        if info then
            if info.sessionID and not state.session_id then
                state.session_id = info.sessionID
            end
            if info.id and not state.message_id then
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

    elseif event_type == "message.part.delta" then
        -- opencode emits delta chunks as their own event with fields:
        -- { sessionID, messageID, partID, field, delta }
        if event_data.sessionID and not state.session_id then
            state.session_id = event_data.sessionID
        end
        if event_data.messageID and not state.message_id then
            state.message_id = event_data.messageID
        end
        if event_data.field == "text" and event_data.delta and event_data.delta ~= "" then
            state.is_thinking = false
            state.current_tool = nil
            if upsert_text_part(state, event_data.partID, event_data.delta, nil) then
                changed = true
            end
        end

    elseif event_type == "permission.asked" then
        -- Payload is the PermissionRequest object directly
        if event_data and event_data.id then
            state.pending_permission = event_data
            if event_data.sessionID and not state.session_id then
                state.session_id = event_data.sessionID
            end
            changed = true
        end

    elseif event_type == "permission.replied" then
        -- Clear pending permission if it matches
        if state.pending_permission and state.pending_permission.id == event_data.requestID then
            state.pending_permission = nil
            changed = true
        end

    elseif event_type == "question.asked" then
        if event_data and event_data.id then
            state.pending_question = event_data
            if event_data.sessionID and not state.session_id then
                state.session_id = event_data.sessionID
            end
            changed = true
        end

    elseif event_type == "question.replied" or event_type == "question.rejected" then
        if state.pending_question and state.pending_question.id == event_data.requestID then
            state.pending_question = nil
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
    local lines = {}
    
    -- Add response text if present
    if state.response_text ~= "" then
        -- Normalize newlines and split
        local text = state.response_text:gsub("\r\n", "\n"):gsub("\r", "\n")
        vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
    end
    
    -- Add questions and options if present
    if state.question then
        vim.list_extend(lines, M.format_question_block(state.question, state.options))
    end
    
    return lines
end

--- Format a question and its options into display lines
---@param question string
---@param options table|nil
---@return table lines
function M.format_question_block(question, options)
    local lines = { "" }
    
    -- Handle question with newlines
    local q_lines = vim.split(question, "\n", { plain = true })
    if #q_lines > 0 then
        table.insert(lines, "**Question:** " .. q_lines[1])
        for i = 2, #q_lines do
            table.insert(lines, q_lines[i])
        end
    end

    if options then
        for i, option in ipairs(options) do
            local label = type(option) == "table" and option.label or tostring(option)
            -- Handle option label with newlines
            local l_lines = vim.split(label, "\n", { plain = true })
            if #l_lines > 0 then
                table.insert(lines, string.format("%d. %s", i, l_lines[1]))
                for j = 2, #l_lines do
                    table.insert(lines, "   " .. l_lines[j]) -- Indent subsequent lines
                end
            end
        end
    end
    table.insert(lines, "")
    return lines
end

return M
