local M = {}

-- =============================================================================
-- Server Module
-- =============================================================================
-- Server management for agentic mode in opencode.nvim
--
-- This module manages the local opencode server process that runs in the
-- background. When running in "agentic" mode, requests are sent to this
-- server using `opencode run --attach <url>` as per the documentation:
-- https://opencode.ai/docs/cli/#attach
--
-- The server is started via `opencode serve --port <port> --hostname <hostname>`
-- and kept running to avoid MCP server cold boot times on every request.

local config = require("opencode.config")

-- =============================================================================
-- Server State Management
-- =============================================================================

--- Get server info for current cwd
---@return table|nil server { process, port, url, agent, model, session_id } or nil
function M.get_server_for_cwd()
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if server and server.process then
        -- Check if process is still running
        local exit_code = server.process:wait(0) -- Non-blocking check
        if exit_code then
            -- Process has exited
            config.state.servers[cwd] = nil
            return nil
        end
        return server
    end
    return nil
end

--- Get the current agent for the server
---@return string agent Current agent name ("build" or "plan")
function M.get_server_agent()
    local server = M.get_server_for_cwd()
    if server and server.agent then
        return server.agent
    end
    return "build" -- Default agent
end

--- Set the agent for the current server
---@param agent string Agent name ("build" or "plan")
function M.set_server_agent(agent)
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if server then
        server.agent = agent
    end
end

--- Get the current model for the server
---@return string|nil model Current model (provider/model format) or nil for default
function M.get_server_model()
    local server = M.get_server_for_cwd()
    if server and server.model then
        return server.model
    end
    return nil
end

--- Set the model for the current server
---@param model string|nil Model in provider/model format (nil for default)
function M.set_server_model(model)
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if server then
        server.model = model
    end
end

--- Get the current session ID for the server
---@return string|nil session_id Current session ID or nil
function M.get_server_session()
    local server = M.get_server_for_cwd()
    if server and server.session_id then
        return server.session_id
    end
    return nil
end

--- Set the session ID for the current server
---@param session_id string|nil Session ID (nil to clear)
function M.set_server_session(session_id)
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if server then
        server.session_id = session_id
    end
end

--- Update all server settings at once
---@param opts table { agent?, model?, session_id? }
function M.update_server_settings(opts)
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if server then
        if opts.agent ~= nil then
            server.agent = opts.agent
        end
        if opts.model ~= nil then
            server.model = opts.model
        end
        if opts.session_id ~= nil then
            server.session_id = opts.session_id
        end
    end
end

--- Sync current global state to the server
--- Call this when model, agent, or session changes in the global state
function M.sync_state_to_server()
    local server = M.get_server_for_cwd()
    if not server then
        return
    end

    -- Sync model from global config state
    server.model = config.state.selected_model

    -- Sync current session
    server.session_id = config.state.current_session_id
end

--- Stop server for current cwd
---@return boolean stopped Whether a server was stopped
function M.stop_server_for_cwd()
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if server then
        if server.process then
            pcall(function() server.process:kill(15) end) -- SIGTERM
            -- Give it a moment, then force kill if needed
            vim.defer_fn(function()
                if server.process then
                    pcall(function() server.process:kill(9) end) -- SIGKILL
                end
            end, 1000)
        end
        config.state.servers[cwd] = nil
        return true
    end
    return false
end

--- Stop all servers (for cleanup)
---@param force? boolean If true, use SIGKILL immediately (default: false, use SIGTERM first)
---@return number count Number of servers stopped
function M.stop_all_servers(force)
    local count = 0
    local servers_to_stop = {}

    -- Collect all servers with processes
    for cwd, srv in pairs(config.state.servers) do
        if srv.process then
            table.insert(servers_to_stop, { cwd = cwd, process = srv.process })
            count = count + 1
        end
    end

    if count == 0 then
        return 0
    end

    if force then
        -- Immediate kill
        for _, srv in ipairs(servers_to_stop) do
            pcall(function() srv.process:kill(9) end) -- SIGKILL
        end
    else
        -- Graceful shutdown: SIGTERM first
        for _, srv in ipairs(servers_to_stop) do
            pcall(function() srv.process:kill(15) end) -- SIGTERM
        end
        -- Schedule force kill after a short delay if still running
        vim.defer_fn(function()
            for _, srv in ipairs(servers_to_stop) do
                -- Check if process is still running and force kill
                pcall(function() srv.process:kill(9) end) -- SIGKILL
            end
        end, 1000)
    end

    config.state.servers = {}
    return count
end

--- Start server for current cwd
---@param callback function Called with (success, url_or_error) when server is ready
function M.start_server_for_cwd(callback)
    local cwd = config.get_cwd()
    local user_config = config.state.user_config

    -- Check if server is already running
    local existing = M.get_server_for_cwd()
    if existing and existing.url then
        callback(true, existing.url)
        return
    end

    -- Check if server is currently starting
    if config.state.servers[cwd] and config.state.servers[cwd].starting then
        -- Wait for it to finish starting (poll)
        local attempts = 0
        local function wait_for_server()
            attempts = attempts + 1
            local server = config.state.servers[cwd]
            if server and server.url then
                callback(true, server.url)
            elseif server and server.starting and attempts < 100 then
                vim.defer_fn(wait_for_server, 100)
            else
                callback(false, "Server startup timed out")
            end
        end
        vim.defer_fn(wait_for_server, 100)
        return
    end

    -- Mark as starting
    config.state.servers[cwd] = { starting = true }

    -- Build command
    local port = user_config.server.port or 0
    local hostname = user_config.server.hostname or "127.0.0.1"
    local cmd = { "opencode", "serve", "--port", tostring(port), "--hostname", hostname }

    local captured_port = nil
    local stderr_lines = {}
    local callback_invoked = false  -- Guard to prevent double callback invocation

    -- Start the server process
    local process = vim.system(cmd, {
        cwd = cwd,
        stdout = function(err, data)
            if data then
                -- Look for port in stdout (format varies, common: "Listening on http://127.0.0.1:XXXXX")
                local port_match = data:match(":(%d+)")
                if port_match and not captured_port and not callback_invoked then
                    captured_port = tonumber(port_match)
                    local url = "http://" .. hostname .. ":" .. captured_port
                    vim.schedule(function()
                        if callback_invoked then return end
                        callback_invoked = true
                        config.state.servers[cwd] = {
                            process = process,
                            port = captured_port,
                            url = url,
                            starting = false,
                            agent = "build", -- Default agent
                            model = config.state.selected_model, -- Sync model from global state
                            session_id = config.state.current_session_id, -- Sync session from global state
                        }
                        callback(true, url)
                    end)
                end
            end
        end,
        stderr = function(err, data)
            if data then
                table.insert(stderr_lines, data)
                -- Also check stderr for port info
                local port_match = data:match(":(%d+)")
                if port_match and not captured_port and not callback_invoked then
                    captured_port = tonumber(port_match)
                    local url = "http://" .. hostname .. ":" .. captured_port
                    vim.schedule(function()
                        if callback_invoked then return end
                        callback_invoked = true
                        config.state.servers[cwd] = {
                            process = process,
                            port = captured_port,
                            url = url,
                            starting = false,
                            agent = "build", -- Default agent
                            model = config.state.selected_model, -- Sync model from global state
                            session_id = config.state.current_session_id, -- Sync session from global state
                        }
                        callback(true, url)
                    end)
                end
            end
        end,
    }, function(result)
        -- Server process exited
        vim.schedule(function()
            if callback_invoked then
                -- Callback already invoked (success or timeout), just clean up
                config.state.servers[cwd] = nil
                return
            end
            if config.state.servers[cwd] and config.state.servers[cwd].starting then
                -- Failed to start
                callback_invoked = true
                config.state.servers[cwd] = nil
                local error_msg = #stderr_lines > 0 and table.concat(stderr_lines, "\n") or "Server exited unexpectedly"
                callback(false, error_msg)
            else
                -- Server stopped (expected or unexpected)
                config.state.servers[cwd] = nil
            end
        end)
    end)

    -- Store process reference immediately so we can track it
    if config.state.servers[cwd] then
        config.state.servers[cwd].process = process
    end

    -- Timeout for server startup
    vim.defer_fn(function()
        if callback_invoked then return end
        if config.state.servers[cwd] and config.state.servers[cwd].starting then
            -- Still starting after timeout - give up
            callback_invoked = true
            if config.state.servers[cwd].process then
                pcall(function() config.state.servers[cwd].process:kill(9) end)
            end
            config.state.servers[cwd] = nil
            callback(false, "Server startup timed out (10s)")
        end
    end, 10000)
end

--- Ensure server is running for current cwd, starting if needed
---@param callback function Called with (success, url_or_error)
function M.ensure_server_running(callback)
    local server = M.get_server_for_cwd()
    if server and server.url then
        callback(true, server.url)
        return
    end
    M.start_server_for_cwd(callback)
end

return M
