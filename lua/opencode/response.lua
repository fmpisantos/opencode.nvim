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

return M
