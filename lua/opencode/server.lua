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
--
-- Server Registry:
-- To prevent multiple opencode servers from running for the same cwd (even across
-- different Neovim instances), we use a registry file that tracks running servers.
-- The registry is stored at ~/.local/share/nvim/opencode/servers.json
--
-- Note: The registry uses simple file-based storage without locking. In rare cases
-- where two Neovim instances race to update the registry simultaneously, one update
-- may be lost. This is an acceptable tradeoff for simplicity - the health check will
-- catch stale entries on the next server start attempt.

local config = require("opencode.config")

-- =============================================================================
-- Server Registry (cross-instance tracking)
-- =============================================================================

local REGISTRY_FILE = vim.fn.stdpath("data") .. "/opencode/servers.json"

--- Load the server registry from disk
---@return table registry { [cwd] = { port, url, pid, nvim_pid } }
local function load_registry()
    if vim.fn.filereadable(REGISTRY_FILE) == 1 then
        local content = vim.fn.readfile(REGISTRY_FILE)
        if #content > 0 then
            local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
            if ok and data then
                return data
            end
        end
    end
    return {}
end

--- Save the server registry to disk
---@param registry table The registry to save
local function save_registry(registry)
    vim.fn.mkdir(vim.fn.fnamemodify(REGISTRY_FILE, ":h"), "p")
    vim.fn.writefile({ vim.json.encode(registry) }, REGISTRY_FILE)
end

--- Register a server in the registry
---@param cwd string Working directory
---@param port number Server port
---@param url string Server URL
---@param pid number|nil Server process ID
local function register_server(cwd, port, url, pid)
    local registry = load_registry()
    registry[cwd] = {
        port = port,
        url = url,
        pid = pid,
        nvim_pid = vim.fn.getpid(),
        timestamp = os.time(),
    }
    save_registry(registry)
end

--- Unregister a server from the registry
---@param cwd string Working directory
local function unregister_server(cwd)
    local registry = load_registry()
    registry[cwd] = nil
    save_registry(registry)
end

--- Check if a server is registered and still alive (async)
---@param cwd string Working directory
---@param callback function Called with (server_info_or_nil)
local function get_registered_server_async(cwd, callback)
    local registry = load_registry()
    local entry = registry[cwd]
    if not entry then
        callback(nil)
        return
    end

    -- Check if the server process is still running via async health check
    vim.system({
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "--connect-timeout", "1",
        entry.url .. "/global/health"
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code == 0 and result.stdout and result.stdout:match("^200") then
                callback(entry)
            else
                -- Server is not responding, clean up the registry entry
                unregister_server(cwd)
                callback(nil)
            end
        end)
    end)
end

-- =============================================================================
-- HTTP API Functions
-- =============================================================================

--- Make an HTTP request to the server
---@param server_url string Server base URL
---@param method string HTTP method (GET, POST, PATCH, etc.)
---@param path string API path (e.g., "/config")
---@param body? table Optional JSON body for POST/PATCH requests
---@param callback function Called with (success, response_data_or_error)
local function http_request(server_url, method, path, body, callback)
    local url = server_url .. path
    local cmd = { "curl", "-s", "-X", method }

    -- Add content type and body for requests with body
    if body then
        table.insert(cmd, "-H")
        table.insert(cmd, "Content-Type: application/json")
        table.insert(cmd, "-d")
        table.insert(cmd, vim.json.encode(body))
    end

    table.insert(cmd, url)

    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, "curl failed with code " .. result.code)
                return
            end

            if result.stdout and result.stdout ~= "" then
                local ok, data = pcall(vim.json.decode, result.stdout)
                if ok then
                    callback(true, data)
                else
                    callback(true, result.stdout)
                end
            else
                callback(true, nil)
            end
        end)
    end)
end

--- Change the default agent on the server via HTTP API
---@param server_url string Server base URL
---@param agent string Agent name ("build" or "plan")
---@param callback? function Optional callback(success, error_message)
function M.set_server_agent_via_api(server_url, agent, callback)
    http_request(server_url, "PATCH", "/config", { default_agent = agent }, function(success, result)
        if callback then
            if success then
                callback(true, nil)
            else
                callback(false, tostring(result))
            end
        end
    end)
end

--- Get the current config from the server via HTTP API
---@param server_url string Server base URL
---@param callback function Called with (success, config_or_error)
function M.get_server_config(server_url, callback)
    http_request(server_url, "GET", "/config", nil, callback)
end

-- =============================================================================
-- Server State Management
-- =============================================================================

--- Get server info for current cwd
---@return table|nil server { process, port, url, agent, model, session_id } or nil
function M.get_server_for_cwd()
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if not server then
        return nil
    end

    -- For external servers (from another Neovim instance), we don't own the process
    -- Just verify the server is still responding via health check
    if server.external then
        -- Async check could cause issues, so we trust the registry until next start_server_for_cwd
        -- which will verify with a health check
        if server.url then
            return server
        end
        return nil
    end

    -- For servers we own, check if process is still running
    if server.process then
        local exit_code = server.process:wait(0) -- Non-blocking check
        if exit_code then
            -- Process has exited, unregister and clean up
            unregister_server(cwd)
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
--- In agentic mode, this also updates the server's default_agent via HTTP API
---@param agent string Agent name ("build" or "plan")
---@param callback? function Optional callback(success, error_message) - only used when server is running
function M.set_server_agent(agent, callback)
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if server then
        server.agent = agent

        -- If server is running and has a URL, update via HTTP API
        if server.url then
            M.set_server_agent_via_api(server.url, agent, function(success, err)
                if not success then
                    vim.notify("Warning: Failed to update agent on server: " .. tostring(err), vim.log.levels.WARN)
                end
                if callback then
                    callback(success, err)
                end
            end)
        elseif callback then
            callback(true, nil)
        end
    elseif callback then
        callback(true, nil)
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

--- Get the server's working directory
---@return string|nil cwd The server's working directory or nil
function M.get_server_cwd()
    local server = M.get_server_for_cwd()
    if server and server.cwd then
        return server.cwd
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
--- For external servers (from another instance), only removes from local state
---@return boolean stopped Whether a server was stopped
function M.stop_server_for_cwd()
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]
    if server then
        -- Only kill process if we own it (not external)
        if server.process and not server.external then
            pcall(function() server.process:kill(15) end) -- SIGTERM
            -- Give it a moment, then force kill if needed
            vim.defer_fn(function()
                if server.process then
                    pcall(function() server.process:kill(9) end) -- SIGKILL
                end
            end, 1000)
            -- Unregister from the global registry only if we own it
            unregister_server(cwd)
        end
        config.state.servers[cwd] = nil
        return true
    end
    return false
end

--- Stop all servers (for cleanup)
--- For external servers, only removes from local state (doesn't kill the process)
---@param force? boolean If true, use SIGKILL immediately (default: false, use SIGTERM first)
---@return number count Number of servers stopped
function M.stop_all_servers(force)
    local count = 0
    local servers_to_stop = {}

    -- Collect all servers we own (with processes, not external)
    for cwd, srv in pairs(config.state.servers) do
        if srv.process and not srv.external then
            table.insert(servers_to_stop, { cwd = cwd, process = srv.process })
            count = count + 1
        end
    end

    if count > 0 then
        if force then
            -- Immediate kill
            for _, srv in ipairs(servers_to_stop) do
                pcall(function() srv.process:kill(9) end) -- SIGKILL
                -- Unregister from the global registry
                unregister_server(srv.cwd)
            end
        else
            -- Graceful shutdown: SIGTERM first
            for _, srv in ipairs(servers_to_stop) do
                pcall(function() srv.process:kill(15) end) -- SIGTERM
                -- Unregister from the global registry
                unregister_server(srv.cwd)
            end
            -- Schedule force kill after a short delay if still running
            vim.defer_fn(function()
                for _, srv in ipairs(servers_to_stop) do
                    -- Check if process is still running and force kill
                    pcall(function() srv.process:kill(9) end) -- SIGKILL
                end
            end, 1000)
        end
    end

    config.state.servers = {}
    return count
end

--- Start server for current cwd
--- Checks the global registry first to avoid starting duplicate servers for the same cwd
---@param callback function Called with (success, url_or_error) when server is ready
function M.start_server_for_cwd(callback)
    local cwd = config.get_cwd()
    local user_config = config.state.user_config

    -- Check if server is already running (in this Neovim instance)
    local existing = M.get_server_for_cwd()
    if existing and existing.url then
        callback(true, existing.url)
        return
    end

    -- Check the global registry for a server running in another instance
    get_registered_server_async(cwd, function(registered)
        if registered then
            -- A server is already running for this cwd (possibly from another Neovim instance)
            -- Connect to it instead of starting a new one
            config.state.servers[cwd] = {
                process = nil, -- We don't own this process
                port = registered.port,
                url = registered.url,
                cwd = cwd,
                starting = false,
                agent = "build", -- Default agent, will be synced via API if needed
                model = config.state.selected_model,
                session_id = config.state.current_session_id,
                external = true, -- Flag to indicate we didn't start this server
            }
            callback(true, registered.url)
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

                            -- Get process ID if available
                            local pid = nil
                            if process and process.pid then
                                pid = process.pid
                            end

                            config.state.servers[cwd] = {
                                process = process,
                                port = captured_port,
                                url = url,
                                cwd = cwd, -- Store cwd for consistency when running commands
                                starting = false,
                                agent = "build", -- Default agent
                                model = config.state.selected_model, -- Sync model from global state
                                session_id = config.state.current_session_id, -- Sync session from global state
                                external = false, -- We own this server
                            }

                            -- Register in the global registry
                            register_server(cwd, captured_port, url, pid)

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

                            -- Get process ID if available
                            local pid = nil
                            if process and process.pid then
                                pid = process.pid
                            end

                            config.state.servers[cwd] = {
                                process = process,
                                port = captured_port,
                                url = url,
                                cwd = cwd, -- Store cwd for consistency when running commands
                                starting = false,
                                agent = "build", -- Default agent
                                model = config.state.selected_model, -- Sync model from global state
                                session_id = config.state.current_session_id, -- Sync session from global state
                                external = false, -- We own this server
                            }

                            -- Register in the global registry
                            register_server(cwd, captured_port, url, pid)

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
                    -- Unregister from registry
                    unregister_server(cwd)
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
                    -- Unregister from registry
                    unregister_server(cwd)
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
    end)
end

--- Ensure server is running for current cwd, starting if needed
--- Checks for both local and external (registered) servers
---@param callback function Called with (success, url_or_error)
function M.ensure_server_running(callback)
    local cwd = config.get_cwd()

    -- Check if we already have a server in local state
    local server = M.get_server_for_cwd()
    if server and server.url then
        callback(true, server.url)
        return
    end

    -- Check the global registry for a server running in another instance
    get_registered_server_async(cwd, function(registered)
        if registered then
            -- A server is already running for this cwd (possibly from another Neovim instance)
            -- Connect to it instead of starting a new one
            config.state.servers[cwd] = {
                process = nil, -- We don't own this process
                port = registered.port,
                url = registered.url,
                cwd = cwd,
                starting = false,
                agent = "build", -- Default agent, will be synced via API if needed
                model = config.state.selected_model,
                session_id = config.state.current_session_id,
                external = true, -- Flag to indicate we didn't start this server
            }
            callback(true, registered.url)
            return
        end

        -- No server found, start one
        M.start_server_for_cwd(callback)
    end)
end

return M
