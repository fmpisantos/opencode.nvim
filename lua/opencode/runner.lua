local M = {}

-- =============================================================================
-- Runner Module
-- =============================================================================
-- OpenCode CLI execution for opencode.nvim
-- 
-- This module handles running opencode commands in two modes:
-- - "quick" mode: Uses `opencode run` directly for one-shot queries
-- - "agentic" mode: Starts a local server via `opencode serve` and uses
--                   `opencode run --attach <url>` to connect to it
--
-- See: https://opencode.ai/docs/cli/#attach

local config = require("opencode.config")
local utils = require("opencode.utils")
local ui = require("opencode.ui")
local session = require("opencode.session")
local requests = require("opencode.requests")
local response = require("opencode.response")
local server = require("opencode.server")

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

    -- Update local server state if agent changed (HTTP API call happens before execution)
    if mode == "agentic" and agent_changed_by_prompt then
        local cwd = config.get_cwd()
        local srv = config.state.servers[cwd]
        if srv then
            srv.agent = agent
        end
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

    -- Function to execute via CLI (quick mode)
    local function execute_cli()
        -- Build command
        local base_cmd = { "opencode", "run", "--agent", agent, "--format", "json" }

        -- Add --model flag if a model is selected
        local model_to_use = state.selected_model
        if model_to_use and model_to_use ~= "" then
            table.insert(base_cmd, "--model")
            table.insert(base_cmd, model_to_use)
        end

        -- Add --session flag if continuing
        if cli_session_id then
            table.insert(base_cmd, "--session")
            table.insert(base_cmd, cli_session_id)
        end
        local cmd = utils.build_opencode_cmd(base_cmd, prompt, all_files)

        -- Build header for this query
        local cmd_display = table.concat(cmd, " "):gsub("\n", "\\n")
        local header_lines = {
            "**Mode:** [quick]",
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
                table.insert(display_lines, "**Error:** " .. utils.sanitize_line(err))
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
                stdout = function(_, data)
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
                    local display_lines = vim.deepcopy(full_header)

                    -- Ensure we have the CLI session ID for saving
                    if final_cli_session_id and not state.current_session_id then
                        state.current_session_id = final_cli_session_id
                        vim.b[buf].opencode_session_id = state.current_session_id
                    end

                    if err then
                        table.insert(display_lines, "**Error:** " .. utils.sanitize_line(err))
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

    -- Function to execute via CLI with --attach flag (agentic mode)
    -- Uses `opencode run --attach <url>` as per https://opencode.ai/docs/cli/#attach
    -- Note: Agent is set via HTTP API (PATCH /config) instead of --agent flag
    ---@param server_url string Server URL to attach to
    local function execute_agentic(server_url)
        -- Get model to use
        local model_to_use = state.selected_model
        local srv = server.get_server_for_cwd()
        if srv and srv.model then
            model_to_use = srv.model
        end

        -- Determine session to use (continue existing or let CLI create new)
        local session_to_use = cli_session_id
        if not session_to_use and srv and srv.session_id then
            session_to_use = srv.session_id
        end

        -- Build command using --attach flag
        -- From docs: opencode run --attach http://localhost:4096 "message"
        -- Note: --agent is NOT used here; agent is set via HTTP API (PATCH /config)
        local base_cmd = { "opencode", "run", "--attach", server_url, "--format", "json" }

        -- Add --model flag if a model is selected
        if model_to_use and model_to_use ~= "" then
            table.insert(base_cmd, "--model")
            table.insert(base_cmd, model_to_use)
        end

        -- Add --session flag if continuing an existing session
        if session_to_use then
            table.insert(base_cmd, "--session")
            table.insert(base_cmd, session_to_use)
        end

        -- Build the full command (with prompt as argument)
        local cmd = utils.build_opencode_cmd(base_cmd, prompt, {})

        -- Build header for this query
        local cmd_display = table.concat(cmd, " "):gsub("\n", "\\n")
        local header_lines = {
            "**Mode:** [agentic] → " .. server_url,
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

        -- State for streaming updates (reuse same pattern as quick mode)
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
            local model_info = model_to_use and (" [" .. config.get_model_display() .. "]") or ""

            -- Add spinner
            local spinner_char = config.SPINNER_FRAMES[spinner_idx]
            spinner_idx = (spinner_idx % #config.SPINNER_FRAMES) + 1

            local response_lines, err, is_thinking, current_tool, tool_status, new_cli_session_id, todos = response.parse_streaming_response(json_lines)

            -- Capture CLI session ID if we don't have one yet
            if new_cli_session_id and not state.current_session_id then
                state.current_session_id = new_cli_session_id
                vim.b[buf].opencode_session_id = state.current_session_id
                -- Also update server session
                server.set_server_session(new_cli_session_id)
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
                table.insert(display_lines, "**Error:** " .. utils.sanitize_line(err))
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

            -- Use the server's cwd to ensure we're running in the same project context
            -- This is important for --attach to work correctly
            local run_cwd = server.get_server_cwd() or config.get_cwd()

            -- Use streaming stdout handler (same as quick mode)
            system_obj = vim.system(cmd, {
                cwd = run_cwd,
                stdout = function(_, data)
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
                    local display_lines = vim.deepcopy(full_header)

                    -- Ensure we have the CLI session ID for saving
                    if final_cli_session_id and not state.current_session_id then
                        state.current_session_id = final_cli_session_id
                        vim.b[buf].opencode_session_id = state.current_session_id
                        server.set_server_session(final_cli_session_id)
                    end

                    if err then
                        table.insert(display_lines, "**Error:** " .. utils.sanitize_line(err))
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

        -- Ensure server is running, then set agent via HTTP API and execute with --attach
        server.ensure_server_running(function(success, url_or_error)
            vim.schedule(function()
                if success then
                    -- Set the agent via HTTP API before executing
                    -- This ensures the server uses the correct agent without --agent flag
                    server.set_server_agent(agent, function(agent_success, agent_err)
                        if not agent_success then
                            vim.notify("Warning: Failed to set agent on server: " .. tostring(agent_err), vim.log.levels.WARN)
                        end
                        execute_agentic(url_or_error)
                    end)
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
        execute_cli()
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
    -- Add --model flag if a model is selected
    if state.selected_model and state.selected_model ~= "" then
        table.insert(base_cmd, "--model")
        table.insert(base_cmd, state.selected_model)
    end
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
            table.insert(display_lines, "**Error:** " .. utils.sanitize_line(err))
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
                table.insert(display_lines, "**Error:** " .. utils.sanitize_line(err))
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
