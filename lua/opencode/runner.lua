local M = {}

-- =============================================================================
-- Runner Module
-- =============================================================================
-- OpenCode CLI execution for opencode.nvim

local config = require("opencode.config")
local utils = require("opencode.utils")
local ui = require("opencode.ui")
local session = require("opencode.session")
local requests = require("opencode.requests")
local response = require("opencode.response")
local server = require("opencode.server")

-- =============================================================================
-- HTTP API Helper for Agentic Mode
-- =============================================================================

--- Create a new session via HTTP API
---@param server_url string Server URL
---@param callback function Called with (success, session_id_or_error)
local function create_session_http(server_url, callback)
    local curl_cmd = {
        "curl", "-s", "-X", "POST",
        server_url .. "/session",
        "-H", "Content-Type: application/json",
        "-d", "{}"
    }

    vim.system(curl_cmd, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, "Failed to create session: " .. (result.stderr or "unknown error"))
                return
            end

            local ok, data = pcall(vim.json.decode, result.stdout)
            if ok and data and data.id then
                callback(true, data.id)
            else
                callback(false, "Invalid response from server")
            end
        end)
    end)
end

--- Post a message via HTTP API and stream the response
---@param server_url string Server URL
---@param session_id string Session ID
---@param prompt string The prompt to send
---@param agent string Agent to use ("build" or "plan")
---@param on_data function Called with each line of output
---@param on_complete function Called when complete with (success, error_msg)
---@return table system_obj The system object for cancellation
local function post_message_http(server_url, session_id, prompt, agent, on_data, on_complete)
    -- Build the message payload
    local payload = {
        parts = {{ type = "text", text = prompt }},
        agent = agent,
    }

    -- Add model if selected
    local state = config.state
    if state.selected_model then
        local provider, model = state.selected_model:match("([^/]+)/(.+)")
        if provider and model then
            payload.providerID = provider
            payload.modelID = model
        end
    end

    local payload_json = vim.json.encode(payload)
    local url = server_url .. "/session/" .. session_id .. "/message"

    -- Use curl with streaming (though the API returns a single response)
    -- The opencode server returns the full response at once
    local curl_cmd = {
        "curl", "-s", "-X", "POST",
        url,
        "-H", "Content-Type: application/json",
        "-d", payload_json
    }

    local stdout_data = ""
    local stderr_data = ""

    local system_obj = vim.system(curl_cmd, {
        text = true,
        stdout = function(err, data)
            if data then
                stdout_data = stdout_data .. data
            end
        end,
        stderr = function(err, data)
            if data then
                stderr_data = stderr_data .. data
            end
        end,
    }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                on_complete(false, "HTTP request failed: " .. stderr_data)
                return
            end

            -- Parse the response
            local ok, data = pcall(vim.json.decode, stdout_data)
            if not ok then
                on_complete(false, "Failed to parse response: " .. stdout_data)
                return
            end

            -- Check for error in response
            if data.info and data.info.error then
                local err = data.info.error
                local err_msg = err.data and err.data.message or err.message or err.name or "Unknown error"
                -- Create error event in streaming format
                local error_event = vim.json.encode({
                    type = "error",
                    sessionID = session_id,
                    error = err
                })
                on_data(error_event)
                on_complete(true, nil) -- Complete without error since we handled it
                return
            end

            -- Convert HTTP API response to streaming format for compatibility
            -- First send step_start
            local step_start = vim.json.encode({
                type = "step_start",
                sessionID = session_id,
                part = { type = "step-start" }
            })
            on_data(step_start)

            -- Send text parts
            if data.parts then
                for _, part in ipairs(data.parts) do
                    if part.type == "text" then
                        local text_event = vim.json.encode({
                            type = "text",
                            sessionID = session_id,
                            part = {
                                type = "text",
                                text = part.text or ""
                            }
                        })
                        on_data(text_event)
                    elseif part.type == "tool-use" or part.type == "tool_use" then
                        local tool_event = vim.json.encode({
                            type = "tool_use",
                            sessionID = session_id,
                            part = part
                        })
                        on_data(tool_event)
                    end
                end
            end

            -- Send step_finish
            local step_finish = vim.json.encode({
                type = "step_finish",
                sessionID = session_id,
                part = { type = "step-finish", reason = "stop" }
            })
            on_data(step_finish)

            on_complete(true, nil)
        end)
    end)

    return system_obj
end

-- =============================================================================
-- Run OpenCode
-- =============================================================================

--- Run opencode with session support
---@param prompt string The prompt to send
---@param files? table Optional array of file paths to attach via --file
---@param source_file? string Optional source file for MD file discovery
function M.run_opencode(prompt, files, source_file)
    if not prompt or prompt == "" then
        return
    end

    local state = config.state

    -- Extract CLI session id from prompt if present (for continuation)
    local cli_session_id
    prompt, cli_session_id = utils.extract_session_from_prompt(prompt)

    -- Determine if this is a continuation of an existing session
    local is_continuation = cli_session_id ~= nil

    -- Get current mode (quick or agentic)
    local mode = config.get_project_mode()

    -- Determine agent mode
    -- In agentic mode, use server's stored agent as default
    local agent = "build"
    local agent_changed_by_prompt = false
    if mode == "agentic" then
        local srv = server.get_server_for_cwd()
        if srv and srv.agent then
            agent = srv.agent
        end
    end
    -- #plan in prompt always overrides
    if prompt:match("#plan") then
        agent = "plan"
        agent_changed_by_prompt = true
        prompt = prompt:gsub("#plan%s*", ""):gsub("%s*#plan", "")
    -- #build in prompt explicitly sets build mode
    elseif prompt:match("#build") then
        agent = "build"
        agent_changed_by_prompt = true
        prompt = prompt:gsub("#build%s*", ""):gsub("%s*#build", "")
    end

    -- Update server agent if it changed (for agentic mode)
    if mode == "agentic" and agent_changed_by_prompt then
        server.set_server_agent(agent)
    end

    -- Set current session if continuing
    if cli_session_id then
        state.current_session_id = cli_session_id
        state.current_session_name = nil
        -- Sync session to server in agentic mode
        if mode == "agentic" then
            server.set_server_session(cli_session_id)
        end
    end

    -- Get existing content if continuing
    local existing_content = {}
    if is_continuation and cli_session_id then
        -- Load from file if we have a session id
        local saved_content = session.load_session(cli_session_id)
        if saved_content then
            existing_content = vim.split(saved_content, "\n", { plain = true })
        elseif state.response_buf and vim.api.nvim_buf_is_valid(state.response_buf) then
            existing_content = vim.api.nvim_buf_get_lines(state.response_buf, 0, -1, false)
        end
    end

    local buf, _ = ui.create_response_split("OpenCode Response", not is_continuation)

    -- Update buffer's session id (may be nil for new sessions until we get it from CLI)
    vim.b[buf].opencode_session_id = state.current_session_id

    -- Collect all files to attach (only in quick mode - agentic mode reads files itself)
    local all_files = {}
    if mode == "quick" then
        -- 1. Files explicitly passed in (e.g., source buffer)
        all_files = files and vim.deepcopy(files) or {}
        local seen_files = {}
        for _, f in ipairs(all_files) do
            seen_files[f] = true
        end

        -- 2. Files referenced with @path in the prompt
        local prompt_files = utils.extract_file_references(prompt)
        for _, f in ipairs(prompt_files) do
            if not seen_files[f] then
                table.insert(all_files, f)
                seen_files[f] = true
            end
        end

        -- 3. MD files discovered up the directory tree (AGENT.md, etc.)
        local md_files = utils.discover_md_files(source_file)
        for _, f in ipairs(md_files) do
            if not seen_files[f] then
                table.insert(all_files, f)
                seen_files[f] = true
            end
        end
    end

    -- Function to actually execute the opencode command
    ---@param server_url? string Server URL for agentic mode (nil for quick mode)
    local function execute_opencode(server_url)
        -- Build command with --session flag if continuing
        local base_cmd = { "opencode", "run", "--agent", agent, "--format", "json" }

        -- Add --model flag if a model is selected
        -- In agentic mode, use server's stored model; otherwise use global state
        local model_to_use = state.selected_model
        if mode == "agentic" then
            local srv = server.get_server_for_cwd()
            if srv and srv.model then
                model_to_use = srv.model
            end
        end
        if model_to_use and model_to_use ~= "" then
            table.insert(base_cmd, "--model")
            table.insert(base_cmd, model_to_use)
        end

        -- Add --attach for agentic mode
        if server_url then
            table.insert(base_cmd, "--attach")
            table.insert(base_cmd, server_url)
        end

        -- Add --session flag if continuing
        -- In agentic mode, prefer server's stored session if no explicit session in prompt
        local session_to_use = cli_session_id
        if mode == "agentic" and not session_to_use then
            local srv = server.get_server_for_cwd()
            if srv and srv.session_id then
                session_to_use = srv.session_id
            end
        end
        if session_to_use then
            table.insert(base_cmd, "--session")
            table.insert(base_cmd, session_to_use)
        end
        local cmd = utils.build_opencode_cmd(base_cmd, prompt, all_files)

        -- Build header for this query
        local mode_display = mode == "agentic" and "[agentic]" or "[quick]"
        local cmd_display = table.concat(cmd, " "):gsub("\n", "\\n")
        local header_lines = {
            "**Mode:** " .. mode_display .. (server_url and (" → " .. server_url) or ""),
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
            vim.list_extend(display_prefix, vim.split(config.SESSION_SEPARATOR, "\n", { plain = true }))
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
            local model_info = state.selected_model and (" [" .. config.get_model_display() .. "]") or ""

            -- Add spinner
            local spinner_char = config.SPINNER_FRAMES[spinner_idx]
            spinner_idx = (spinner_idx % #config.SPINNER_FRAMES) + 1

            local response_lines, err, is_thinking, current_tool, tool_status, new_cli_session_id, todos = response.parse_streaming_response(json_lines)

            -- Capture CLI session ID if we don't have one yet
            if new_cli_session_id and not state.current_session_id then
                state.current_session_id = new_cli_session_id
                vim.b[buf].opencode_session_id = state.current_session_id
                -- Sync session to server in agentic mode
                if mode == "agentic" then
                    server.set_server_session(new_cli_session_id)
                end
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
                vim.list_extend(display_lines, utils.format_todo_list(todos))
            end

            if err then
                table.insert(display_lines, "**Error:** " .. err)
                utils.append_stderr_block(display_lines, stderr_output)
            elseif #response_lines > 0 then
                vim.list_extend(display_lines, response_lines)
            elseif not is_running then
                table.insert(display_lines, "No response received.")
                utils.append_stderr_block(display_lines, stderr_output)
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
            update_timer = vim.fn.timer_start(config.SPINNER_INTERVAL_MS, function()
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
                    table.insert(display_lines, "**Error:** Request timed out after " .. math.floor(state.user_config.timeout_ms / 1000) .. " seconds")
                    utils.append_stderr_block(display_lines, stderr_output)
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                    -- Save session even on timeout (only if we have a session ID)
                    if state.current_session_id then
                        session.save_session(state.current_session_id, table.concat(display_lines, "\n"))
                    end
                end
            end)
        end

        local function execute()
            -- Start run timer
            run_start_time = vim.loop.now()

            -- Only start timeout timer if timeout_ms is not -1
            if state.user_config.timeout_ms ~= -1 then
                vim.fn.timer_start(state.user_config.timeout_ms, function()
                    if is_running then
                        handle_timeout()
                    end
                end)
            end

            -- Use streaming stdout handler
            system_obj = vim.system(cmd, {
                cwd = config.get_cwd(),
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
                        requests.unregister_request(request_id)
                    end

                    -- Final update
                    local response_lines, err, _, _, _, final_cli_session_id = response.parse_streaming_response(json_lines)
                    local display_lines = vim.deepcopy(full_header)

                    -- Ensure we have the CLI session ID for saving
                    if final_cli_session_id and not state.current_session_id then
                        state.current_session_id = final_cli_session_id
                        vim.b[buf].opencode_session_id = state.current_session_id
                        -- Sync session to server in agentic mode
                        if mode == "agentic" then
                            server.set_server_session(final_cli_session_id)
                        end
                    end

                    if err then
                        table.insert(display_lines, "**Error:** " .. err)
                        utils.append_stderr_block(display_lines, stderr_output)
                    elseif #response_lines == 0 then
                        if result.code ~= 0 then
                            table.insert(display_lines, "**Error:** opencode exited with code " .. result.code)
                            utils.append_stderr_block(display_lines, stderr_output)
                        else
                            table.insert(display_lines, "No response received.")
                            utils.append_stderr_block(display_lines, stderr_output)
                        end
                    else
                        vim.list_extend(display_lines, response_lines)
                    end

                    -- Update buffer if still valid
                    if vim.api.nvim_buf_is_valid(buf) then
                        vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                    end

                    -- Save session to file (only if we have a CLI session ID)
                    if state.current_session_id then
                        session.save_session(state.current_session_id, table.concat(display_lines, "\n"))
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
            request_id = requests.register_request(system_obj, cleanup_fn)

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
                        requests.unregister_request(request_id)
                    end
                end,
            })
        end

        -- Start spinner and execute immediately
        update_display()
        start_update_timer()
        execute()
    end

    -- Execute based on mode
    if mode == "agentic" then
        -- Show "starting server" message in buffer
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "**Mode:** [agentic]",
            "",
            "Starting opencode server... " .. config.SPINNER_FRAMES[1],
        })

        -- Ensure server is running, then execute
        server.ensure_server_running(function(success, url_or_error)
            vim.schedule(function()
                if success then
                    execute_opencode(url_or_error)
                else
                    -- Server failed to start
                    if vim.api.nvim_buf_is_valid(buf) then
                        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                            "**Mode:** [agentic]",
                            "",
                            "**Error:** Failed to start opencode server",
                            "",
                            "```",
                            tostring(url_or_error),
                            "```",
                            "",
                            "Try switching to quick mode with `:OCMode quick` or check server logs.",
                        })
                    end
                end
            end)
        end)
    else
        -- Quick mode: execute immediately
        execute_opencode(nil)
    end
end

-- =============================================================================
-- Run OpenCode Command (slash commands)
-- =============================================================================

--- Run an opencode slash command
---@param command string The command name (e.g., "review", "init")
---@param args? string Optional command arguments
function M.run_opencode_command(command, args)
    local state = config.state

    -- Clear session for new command (session ID will be set when we get it from CLI)
    state.current_session_id = nil
    state.current_session_name = nil

    local buf, _ = ui.create_response_split("OpenCode Response", true)

    -- Extract file references from args if present
    local files = {}
    if args and args ~= "" then
        files = utils.extract_file_references(args)
    end

    -- Build command
    local base_cmd = { "opencode", "run", "--agent", "build", "--format", "json", "--command", command }
    local cmd = utils.build_opencode_cmd(base_cmd, (args and args ~= "") and args or nil, files)

    -- Build header
    local model_info = state.selected_model and (" [" .. config.get_model_display() .. "]") or ""
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
        local spinner_char = config.SPINNER_FRAMES[spinner_idx]
        spinner_idx = (spinner_idx % #config.SPINNER_FRAMES) + 1

        local response_lines, err, is_thinking, current_tool, tool_status, new_cli_session_id = response.parse_streaming_response(json_lines)

        -- Capture CLI session ID if we don't have one yet
        if new_cli_session_id and not state.current_session_id then
            state.current_session_id = new_cli_session_id
            vim.b[buf].opencode_session_id = state.current_session_id
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
            utils.append_stderr_block(display_lines, stderr_output)
        elseif #response_lines > 0 then
            vim.list_extend(display_lines, response_lines)
        elseif not is_running then
            table.insert(display_lines, "No response received.")
            utils.append_stderr_block(display_lines, stderr_output)
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
        update_timer = vim.fn.timer_start(config.SPINNER_INTERVAL_MS, function()
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
                table.insert(display_lines, "**Error:** Request timed out after " .. math.floor(state.user_config.timeout_ms / 1000) .. " seconds")
                utils.append_stderr_block(display_lines, stderr_output)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
                if state.current_session_id then
                    session.save_session(state.current_session_id, table.concat(display_lines, "\n"))
                end
            end
        end)
    end

    -- Start timeout timer only if timeout_ms is not -1
    if state.user_config.timeout_ms ~= -1 then
        vim.fn.timer_start(state.user_config.timeout_ms, function()
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
        cwd = config.get_cwd(),
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
                requests.unregister_request(request_id)
            end

            -- Final update
            local response_lines, err, _, _, _, final_cli_session_id = response.parse_streaming_response(json_lines)
            local display_lines = vim.deepcopy(header_lines)

            -- Ensure we have the CLI session ID for saving
            if final_cli_session_id and not state.current_session_id then
                state.current_session_id = final_cli_session_id
                vim.b[buf].opencode_session_id = state.current_session_id
            end

            if err then
                table.insert(display_lines, "**Error:** " .. err)
                utils.append_stderr_block(display_lines, stderr_output)
            elseif #response_lines == 0 then
                if result.code ~= 0 then
                    table.insert(display_lines, "**Error:** opencode exited with code " .. result.code)
                    utils.append_stderr_block(display_lines, stderr_output)
                else
                    table.insert(display_lines, "Command completed successfully.")
                    utils.append_stderr_block(display_lines, stderr_output)
                end
            else
                vim.list_extend(display_lines, response_lines)
            end

            -- Update buffer if still valid
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
            end

            -- Save session (only if we have a CLI session ID)
            if state.current_session_id then
                session.save_session(state.current_session_id, table.concat(display_lines, "\n"))
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
    request_id = requests.register_request(system_obj, cleanup_fn)

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
                requests.unregister_request(request_id)
            end
        end,
    })
end

return M
