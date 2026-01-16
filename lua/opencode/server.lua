local M = {}

-- =============================================================================
-- Server Module
-- =============================================================================
-- Server management for agentic mode in opencode.nvim

local config = require("opencode.config")

-- =============================================================================
-- Server State Management
-- =============================================================================

--- Get server info for current cwd
---@return table|nil server { process, port, url } or nil
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
---@return number count Number of servers stopped
function M.stop_all_servers()
    local count = 0
    for cwd, server in pairs(config.state.servers) do
        if server.process then
            pcall(function() server.process:kill(9) end)
            count = count + 1
        end
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
