local M = {}

-- =============================================================================
-- Requests Module
-- =============================================================================
-- Active request tracking and queue management for opencode.nvim
--
-- This module ensures only one request is actively updating the response buffer
-- at a time. Additional requests are queued and processed sequentially.

local config = require("opencode.config")

-- =============================================================================
-- Queue State
-- =============================================================================

---@class QueuedRequest
---@field prompt string The prompt to send
---@field files table|nil Optional array of file paths
---@field source_file string|nil Optional source file for MD discovery
---@field queued_at number Timestamp when queued

---@type QueuedRequest[]
M.queue = {}

---@type boolean Whether a request is currently running
M.is_busy = false

---@type function|nil Callback to process queued requests
M.process_queue_fn = nil

---@type boolean Flag to temporarily suspend queue processing (used during bulk cancel)
M.queue_suspended = false

-- =============================================================================
-- Queue Management
-- =============================================================================

--- Check if the response buffer is busy with a request
---@return boolean
function M.is_response_busy()
    return M.is_busy
end

--- Set the busy state
---@param busy boolean
function M.set_busy(busy)
    M.is_busy = busy
    -- If no longer busy and queue is not suspended, process next queued request
    if not busy and not M.queue_suspended and #M.queue > 0 and M.process_queue_fn then
        local next_request = table.remove(M.queue, 1)
        -- Reserve the slot immediately to prevent race conditions
        -- (another request could check is_busy before vim.schedule runs)
        M.is_busy = true
        vim.schedule(function()
            M.process_queue_fn(next_request.prompt, next_request.files, next_request.source_file)
        end)
    end
end

--- Add a request to the queue
---@param prompt string
---@param files table|nil
---@param source_file string|nil
---@return number position Position in queue (1-based)
function M.enqueue_request(prompt, files, source_file)
    table.insert(M.queue, {
        prompt = prompt,
        files = files,
        source_file = source_file,
        queued_at = vim.loop.now(),
    })
    return #M.queue
end

--- Get the current queue length
---@return number
function M.get_queue_length()
    return #M.queue
end

--- Clear all queued requests
---@return number count Number of requests cleared
function M.clear_queue()
    local count = #M.queue
    M.queue = {}
    return count
end

--- Set the function to call when processing queued requests
---@param fn function Function that takes (prompt, files, source_file)
function M.set_queue_processor(fn)
    M.process_queue_fn = fn
end

-- =============================================================================
-- Request Management
-- =============================================================================

--- Register an active request for tracking/cancellation
---@param system_obj table The vim.system object
---@param cleanup_fn? function Optional cleanup function to call on cancel
---@return number request_id The ID of the registered request
function M.register_request(system_obj, cleanup_fn)
    config.state.next_request_id = config.state.next_request_id + 1
    config.state.active_requests[config.state.next_request_id] = {
        system_obj = system_obj,
        cleanup_fn = cleanup_fn,
    }
    return config.state.next_request_id
end

--- Unregister a completed request
---@param request_id number The request ID to unregister
function M.unregister_request(request_id)
    config.state.active_requests[request_id] = nil
end

--- Cancel a specific request
---@param request_id number The request ID to cancel
function M.cancel_request(request_id)
    local request = config.state.active_requests[request_id]
    if request then
        if request.system_obj then
            pcall(function() request.system_obj:kill(9) end)
        end
        if request.cleanup_fn then
            pcall(request.cleanup_fn)
        end
        config.state.active_requests[request_id] = nil
    end
end

--- Cancel all active requests
---@return number count Number of requests cancelled
function M.cancel_all_requests()
    local count = 0
    -- Suspend queue processing during bulk cancel
    M.queue_suspended = true
    for id, _ in pairs(config.state.active_requests) do
        M.cancel_request(id)
        count = count + 1
    end
    -- Resume queue processing
    M.queue_suspended = false
    -- Always reset busy state to allow queue processing
    -- This handles edge cases where is_busy is true but no requests were registered
    M.set_busy(false)
    return count
end

--- Get count of active requests
---@return number
function M.get_active_request_count()
    local count = 0
    for _ in pairs(config.state.active_requests) do
        count = count + 1
    end
    return count
end

return M
