local M = {}

-- =============================================================================
-- Requests Module
-- =============================================================================
-- Active request tracking for opencode.nvim

local config = require("opencode.config")

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
    for id, _ in pairs(config.state.active_requests) do
        M.cancel_request(id)
        count = count + 1
    end
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
