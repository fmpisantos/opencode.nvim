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

--- URL encode a string
---@param str string String to encode
---@return string Encoded string
local function url_encode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w %-%_%.%~])",
            function(c) return string.format("%%%02X", string.byte(c)) end)
        str = string.gsub(str, " ", "%%20")
    end
    return str
end

--- Make an HTTP request to the server
---@param server_url string Server base URL
---@param method string HTTP method (GET, POST, PATCH, etc.)
---@param path string API path (e.g., "/config")
---@param body? table Optional JSON body for POST/PATCH requests
---@param callback function Called with (success, response_data_or_error)
local function http_request(server_url, method, path, body, callback)
    local url = server_url .. path
    local cmd = { "curl", "-s", "-X", method, "--fail-with-body" }

    -- Add content type and body for requests with body
    if body then
        table.insert(cmd, "-H")
        table.insert(cmd, "Content-Type: application/json")
        table.insert(cmd, "-d")
        table.insert(cmd, vim.json.encode(body))
    end

    table.insert(cmd, url)

    -- Construct a shell-safe command string for debugging
    local debug_cmd = {}
    for i, part in ipairs(cmd) do
        -- Don't quote the curl options like -s, -X, etc. for readability
        -- But DO quote the URL and the JSON body
        if part:match("^{.*}$") or part:match("^http") or part:match(" ") then
            table.insert(debug_cmd, vim.fn.shellescape(part))
        else
            table.insert(debug_cmd, part)
        end
    end
    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                -- curl failed - could be connection error or HTTP error (--fail-with-body)
                local error_msg = "curl failed with code " .. result.code
                if result.stderr and result.stderr ~= "" then
                    error_msg = error_msg .. ": " .. result.stderr
                elseif result.stdout and result.stdout ~= "" then
                    -- --fail-with-body includes response body in stdout even on HTTP errors
                    error_msg = error_msg .. ": " .. result.stdout
                end
                callback(false, error_msg)
                return
            end

            if result.stdout and result.stdout ~= "" then
                local ok, data = pcall(vim.json.decode, result.stdout)
                if ok then
                    callback(true, data)
                else
                    -- JSON decode failed - return as string with warning
                    callback(false, "Invalid JSON response: " .. result.stdout:sub(1, 100))
                end
            else
                -- Empty response
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
    local body = { default_agent = agent }
    http_request(server_url, "PATCH", "/config", body, function(success, result)
        if callback then
            if success then
                -- Check if the response contains the updated default_agent
                if type(result) == "table" and result.default_agent then
                    if result.default_agent ~= agent then
                        callback(false,
                            "Server did not update default_agent (got: " ..
                            tostring(result.default_agent) .. ", expected: " .. agent .. ")")
                        return
                    end
                end
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

--- Create a new session via HTTP API
---@param server_url string Server base URL
---@param title? string Optional session title
---@param callback function Called with (success, session_or_error)
function M.create_session(server_url, title, callback)
    local body = nil
    if title then
        body = { title = title }
    end
    http_request(server_url, "POST", "/session", body, callback)
end

--- Send a message to a session via HTTP API (async, uses prompt_async)
--- This sends the message and returns immediately. Use event stream to get response.
---@param server_url string Server base URL
---@param session_id string Session ID
---@param message string The message text
---@param opts? table Optional { agent?: string, model?: string, noReply?: boolean }
---@param callback function Called with (success, error_or_nil)
function M.send_message_async(server_url, session_id, message, opts, callback)
    opts = opts or {}
    local body = {
        parts = {
            {
                type = "text",
                text = message,
            }
        }
    }
    if opts.agent then
        body.agent = opts.agent
    end
    if opts.noReply ~= nil then
        body.noReply = opts.noReply
    end
    if opts.model then
        local providerID, modelID = string.match(opts.model, "([^/]+)/([^/]+)")
        if providerID and modelID then
            body.model = {
                providerID = providerID,
                modelID = modelID,
            }
        else
            vim.notify("Invalid model format. Expected 'providerID/modelID'", vim.log.levels.ERROR)
        end
    end

    local cwd = config.get_cwd()
    local path = "/session/" .. session_id .. "/prompt_async?directory=" .. url_encode(cwd)
    http_request(server_url, "POST", path, body, function(success, result)
        if callback then
            callback(success, success and nil or tostring(result))
        end
    end)
end

--- List all sessions via HTTP API
---@param server_url string Server base URL
---@param callback function Called with (success, sessions_or_error)
function M.list_sessions(server_url, callback)
    http_request(server_url, "GET", "/session", nil, callback)
end

--- Get or create a session for use with HTTP API
--- Returns an existing session if one is active, or creates a new one
---@param server_url string Server base URL
---@param opts? table { session_id?: string, title?: string }
---@param callback function Called with (success, session_id_or_error)
function M.get_or_create_session(server_url, opts, callback)
    opts = opts or {}

    -- If we already have a session ID, use it
    if opts.session_id then
        callback(true, opts.session_id)
        return
    end

    -- Check if we have a session in server state
    local srv = M.get_server_for_cwd()
    if srv and srv.session_id then
        callback(true, srv.session_id)
        return
    end

    -- Create a new session
    M.create_session(server_url, opts.title, function(success, result)
        if success and type(result) == "table" and result.id then
            -- Store the session ID
            M.set_server_session(result.id)
            callback(true, result.id)
        elseif success then
            -- Got a response but it wasn't a valid session object
            callback(false, "Invalid session response: expected table with 'id' field, got " .. type(result))
        else
            callback(false, result)
        end
    end)
end

--- Abort a running session
---@param server_url string Server base URL
---@param session_id string Session ID to abort
---@param callback? function Called with (success, error_or_nil)
function M.abort_session(server_url, session_id, callback)
    local path = "/session/" .. session_id .. "/abort"
    http_request(server_url, "POST", path, nil, function(success, result)
        if callback then
            callback(success, success and nil or tostring(result))
        end
    end)
end

-- =============================================================================
-- SSE Event Stream
-- =============================================================================

---@class SSEConnection
---@field process table|nil vim.system process object
---@field url string Server URL
---@field is_connected boolean Whether the connection is active
---@field on_event function Callback for events
---@field on_error function|nil Callback for errors
---@field on_close function|nil Callback when connection closes

--- Create an SSE connection to the server's event stream
--- The event stream provides real-time updates for messages, tool calls, etc.
---@param server_url string Server base URL
---@param on_event function Called with (event_type, event_data) for each event
---@param on_error? function Called with (error_message) on errors
---@param on_close? function Called when connection closes
---@return SSEConnection connection Object with :close() method
function M.connect_event_stream(server_url, on_event, on_error, on_close)
    local url = server_url .. "/event"
    local connection = {
        process = nil,
        url = url,
        is_connected = false,
        on_event = on_event,
        on_error = on_error,
        on_close = on_close,
    }

    -- Buffer for incomplete SSE data
    local buffer = ""

    -- Parse SSE data format:
    -- event: <event_type>
    -- data: <json_data>
    -- (blank line)
    local function parse_sse_chunk(chunk)
        buffer = buffer .. chunk
        local events = {}

        -- SSE events are separated by double newlines
        while true do
            local event_end = buffer:find("\n\n")
            if not event_end then
                break
            end

            local event_text = buffer:sub(1, event_end - 1)
            buffer = buffer:sub(event_end + 2)

            -- Parse the event
            local event_type = nil
            local event_data = nil

            for line in event_text:gmatch("[^\r\n]+") do
                if line:match("^event:%s*") then
                    event_type = line:gsub("^event:%s*", "")
                elseif line:match("^data:%s*") then
                    local data_str = line:gsub("^data:%s*", "")
                    -- Try to parse as JSON
                    local ok, parsed = pcall(vim.json.decode, data_str)
                    if ok then
                        -- SSE events from opencode server wrap data in "properties" field
                        -- Unwrap it for easier consumption by event handlers
                        if type(parsed) == "table" and parsed.properties then
                            event_data = parsed.properties
                        else
                            event_data = parsed
                        end
                    else
                        event_data = data_str
                    end
                end
            end

            if event_type or event_data then
                table.insert(events, { type = event_type, data = event_data })
            end
        end

        return events
    end

    -- Use curl with -N (no buffering) for SSE
    -- Use --fail-with-body to get proper error handling
    local cmd = {
        "curl", "-s", "-N",
        "-H", "Accept: text/event-stream",
        url
    }

    -- Accumulate stderr to report only on connection close with non-zero exit
    local stderr_buffer = {}

    connection.process = vim.system(cmd, {
        stdout = function(_, data)
            if data then
                vim.schedule(function()
                    local events = parse_sse_chunk(data)
                    for _, event in ipairs(events) do
                        if event.type == "server.connected" then
                            connection.is_connected = true
                        end
                        on_event(event.type, event.data)
                    end
                end)
            end
        end,
        stderr = function(_, data)
            -- Accumulate stderr instead of treating each chunk as an error
            -- curl may output non-error diagnostics to stderr
            if data then
                table.insert(stderr_buffer, data)
            end
        end,
    }, function(result)
        vim.schedule(function()
            connection.is_connected = false
            -- Only report stderr as error if curl exited with non-zero and we have stderr
            if result.code ~= 0 and #stderr_buffer > 0 and on_error then
                on_error("SSE connection failed: " .. table.concat(stderr_buffer, ""))
            end
            if on_close then
                on_close(result.code)
            end
        end)
    end)

    --- Close the SSE connection
    function connection:close()
        self.is_connected = false
        if self.process then
            pcall(function() self.process:kill(9) end)
            self.process = nil
        end
    end

    return connection
end

-- =============================================================================
-- Server State Management
-- =============================================================================

--- Check if a registered server is still alive (synchronous)
---@param entry table Registry entry { port, url, pid, nvim_pid, timestamp }
---@return boolean alive Whether the server responds to health check
local function check_server_health_sync(entry)
    local result = vim.fn.system({
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "--connect-timeout", "1",
        entry.url .. "/global/health"
    })
    return result and result:match("^200") ~= nil
end

--- Get server info for current cwd
---@return table|nil server { process, port, url, agent, model, session_id } or nil
function M.get_server_for_cwd()
    local cwd = config.get_cwd()
    local server = config.state.servers[cwd]

    -- If no server in memory, check the registry for external servers
    if not server then
        local registry = load_registry()
        local entry = registry[cwd]
        if entry and entry.url then
            -- Verify the server is still responding via synchronous health check
            if check_server_health_sync(entry) then
                -- Server is alive, add it to local state as external
                config.state.servers[cwd] = {
                    process = nil, -- We don't own this process
                    port = entry.port,
                    url = entry.url,
                    cwd = cwd,
                    starting = false,
                    agent = "build", -- Default agent
                    model = config.state.selected_model,
                    session_id = config.state.current_session_id,
                    external = true, -- Flag to indicate we didn't start this server
                }
                return config.state.servers[cwd]
            else
                -- Server is not responding, clean up the registry entry
                unregister_server(cwd)
            end
        end
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
            local pid = server.process.pid
            if pid then
                -- Kill child processes first (opencode spawns child processes)
                vim.fn.system({ "pkill", "-15", "-P", tostring(pid) })
                vim.fn.system({ "kill", "-15", tostring(pid) })
                -- Give it a moment, then force kill if needed
                -- Only capture pid for the deferred callback to avoid stale references
                vim.defer_fn(function()
                    -- Force kill children and parent using system calls
                    vim.fn.system({ "pkill", "-9", "-P", tostring(pid) })
                    vim.fn.system({ "kill", "-9", tostring(pid) })
                end, 1000)
            end
            -- Unregister from the global registry only if we own it
            unregister_server(cwd)
        end
        config.state.servers[cwd] = nil
        return true
    end
    return false
end

--- Kill a process and its children by PID using synchronous system call
--- This is used during VimLeavePre to ensure the server is killed before Neovim exits
--- The opencode CLI spawns child processes, so we need to kill the entire process tree
---@param pid number Process ID to kill
local function kill_process_tree_sync(pid)
    -- Use pkill to kill the process tree by parent PID
    -- This handles the case where opencode (Node.js) spawns child processes
    -- First try SIGTERM for graceful shutdown of all children
    vim.fn.system({ "pkill", "-15", "-P", tostring(pid) })
    vim.fn.system({ "kill", "-15", tostring(pid) })

    -- Give processes a brief moment to terminate gracefully, then force kill
    vim.fn.system({
        "sh", "-c",
        string.format(
            "sleep 0.2; pkill -9 -P %d 2>/dev/null; kill -9 %d 2>/dev/null",
            pid, pid
        )
    })
end

--- Stop all servers (for cleanup)
--- For external servers, only removes from local state (doesn't kill the process)
---@param force? boolean If true, skip graceful shutdown and use SIGKILL immediately (default: false)
---@return number count Number of servers stopped
function M.stop_all_servers(force)
    local count = 0
    local servers_to_stop = {}

    -- Collect all servers we own (with processes, not external)
    for cwd, srv in pairs(config.state.servers) do
        if srv.process and not srv.external then
            local pid = srv.process.pid
            if pid then
                table.insert(servers_to_stop, { cwd = cwd, process = srv.process, pid = pid })
                count = count + 1
            end
        end
    end

    if count > 0 then
        for _, srv in ipairs(servers_to_stop) do
            if force then
                -- Immediate SIGKILL of process tree (used during VimLeavePre for fast cleanup)
                -- Kill children first, then parent
                vim.fn.system({ "pkill", "-9", "-P", tostring(srv.pid) })
                vim.fn.system({ "kill", "-9", tostring(srv.pid) })
            else
                -- Graceful shutdown: SIGTERM, then wait briefly, then SIGKILL if needed
                kill_process_tree_sync(srv.pid)
            end
            -- Unregister from the global registry
            unregister_server(srv.cwd)
        end
    end

    config.state.servers = {}
    return count
end

--- Check if a port is available (synchronous)
---@param port number Port to check
---@param hostname string Hostname to check
---@return boolean available Whether the port is available
local function is_port_available(port, hostname)
    -- Try to connect to the port - if it fails, the port is available
    vim.fn.system({
        "curl", "-s", "-o", "/dev/null",
        "--connect-timeout", "1",
        string.format("http://%s:%d/", hostname, port)
    })
    -- If curl fails to connect (exit code non-zero or connection refused), port is available
    return vim.v.shell_error ~= 0
end

--- Find the first available port from the configured list
---@param ports table List of ports to try
---@param hostname string Hostname to check
---@return number port First available port, or 0 if none available
local function find_available_port(ports, hostname)
    for _, port in ipairs(ports) do
        if is_port_available(port, hostname) then
            return port
        end
    end
    -- All predefined ports are in use, fall back to OS-assigned port
    return 0
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

        -- Find an available port from the configured list
        local hostname = user_config.server.hostname or "127.0.0.1"
        local ports = user_config.server.ports or { 4096, 4097, 4098, 4099, 4100, 4101, 4102, 4103, 4104, 4105 }
        local port = find_available_port(ports, hostname)

        local cmd = { "opencode", "serve", "--port", tostring(port), "--hostname", hostname }

        local captured_port = nil
        local stderr_lines = {}
        local callback_invoked = false -- Guard to prevent double callback invocation

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
                                cwd = cwd,                                    -- Store cwd for consistency when running commands
                                starting = false,
                                agent = "build",                              -- Default agent
                                model = config.state.selected_model,          -- Sync model from global state
                                session_id = config.state.current_session_id, -- Sync session from global state
                                external = false,                             -- We own this server
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
                                cwd = cwd,                                    -- Store cwd for consistency when running commands
                                starting = false,
                                agent = "build",                              -- Default agent
                                model = config.state.selected_model,          -- Sync model from global state
                                session_id = config.state.current_session_id, -- Sync session from global state
                                external = false,                             -- We own this server
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
                    local error_msg = #stderr_lines > 0 and table.concat(stderr_lines, "\n") or
                        "Server exited unexpectedly"
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

--- Retrieve port number for current cwd's server
--- @return number|nil port Port number or nil if no server
function M.get_server_port()
    local server = M.get_server_for_cwd()
    if server and server.port then
        return server.port
    end
    return nil
end

return M
