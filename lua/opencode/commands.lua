local M = {}

-- =============================================================================
-- Commands Module
-- =============================================================================
-- This module defines all Neovim user commands and keymaps for opencode.nvim
-- It separates command registration from the main plugin logic

---@class CommandsConfig
---@field keymaps { enable_default: boolean, open_prompt: string }
---@field prompt_window { width: number, height: number }

-- =============================================================================
-- Helper Functions
-- =============================================================================

--- Get the source file from current buffer
---@return string|nil
local function get_source_file()
    local bufname = vim.fn.expand("%")
    local buftype = vim.bo.buftype
    local filetype = vim.bo.filetype

    if bufname == "" or buftype ~= "" or filetype == "netrw" or filetype == "oil" then
        return nil
    end
    if vim.fn.filereadable(bufname) == 0 then
        return nil
    end

    -- Convert to path relative to cwd
    local full_path = vim.fn.fnamemodify(bufname, ":p")
    local cwd = vim.fn.getcwd()
    if not cwd:match("/$") then
        cwd = cwd .. "/"
    end

    -- If the file is under cwd, return relative path
    if full_path:sub(1, #cwd) == cwd then
        return full_path:sub(#cwd + 1)
    end

    -- Otherwise return the original bufname (could be relative already)
    return bufname
end

-- =============================================================================
-- Command Definitions
-- =============================================================================

--- Setup all user commands
---@param opencode table The main opencode module (M from init.lua)
local function setup_commands(opencode)
    -- Main command (OpenCode / OC)
    vim.api.nvim_create_user_command("OpenCode", function()
        opencode.OpenCode(nil, nil, get_source_file())
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OC", function()
        opencode.OpenCode(nil, nil, get_source_file())
    end, { nargs = 0 })

    -- With selection
    vim.api.nvim_create_user_command("OpenCodeWSelection", function()
        local source_file = get_source_file()
        local mode = vim.fn.mode()

        if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
            opencode.OpenCode(nil, nil, source_file)
            return
        end

        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local selection_lines = vim.fn.getregion(start_pos, end_pos, { type = mode })
        opencode.OpenCode(selection_lines, vim.bo.filetype, source_file)
    end, { nargs = 0 })

    -- Model selection
    vim.api.nvim_create_user_command("OpenCodeModel", function()
        opencode.SelectModel()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCModel", function()
        opencode.SelectModel()
    end, { nargs = 0 })

    -- Review
    vim.api.nvim_create_user_command("OpenCodeReview", function()
        opencode.OpenCodeReview()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCReview", function()
        opencode.OpenCodeReview()
    end, { nargs = 0 })

    -- CLI toggle
    vim.api.nvim_create_user_command("OpenCodeCLI", function()
        opencode.ToggleCLI()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCCLI", function()
        opencode.ToggleCLI()
    end, { nargs = 0 })

    -- Sessions
    vim.api.nvim_create_user_command("OpenCodeSessions", function()
        opencode.SelectSession()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCSessions", function()
        opencode.SelectSession()
    end, { nargs = 0 })

    -- Init (runs /init command)
    vim.api.nvim_create_user_command("OpenCodeInit", function()
        opencode.Init()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCInit", function()
        opencode.Init()
    end, { nargs = 0 })

    -- Stop all active requests
    vim.api.nvim_create_user_command("OpenCodeStop", function()
        opencode.StopAll()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCStop", function()
        opencode.StopAll()
    end, { nargs = 0 })

    -- Attach prompt to window
    vim.api.nvim_create_user_command("OpenCodeAttachWindow", function()
        opencode.AttachWindow()
    end, { nargs = 0 })
    vim.api.nvim_create_user_command("OCAttachWindow", function()
        opencode.AttachWindow()
    end, { nargs = 0 })

    -- Mode management (quick/agentic toggle)
    vim.api.nvim_create_user_command("OpenCodeMode", function(opts)
        local arg = opts.args and opts.args ~= "" and opts.args or nil
        opencode.SetMode(arg)
    end, {
        nargs = "?",
        complete = function() return { "quick", "agentic" } end,
        desc = "Toggle or set OpenCode mode (quick/agentic)",
    })
    vim.api.nvim_create_user_command("OCMode", function(opts)
        local arg = opts.args and opts.args ~= "" and opts.args or nil
        opencode.SetMode(arg)
    end, {
        nargs = "?",
        complete = function() return { "quick", "agentic" } end,
        desc = "Toggle or set OpenCode mode (quick/agentic)",
    })

    -- Server management
    vim.api.nvim_create_user_command("OpenCodeServerStatus", function()
        opencode.ServerStatus()
    end, { nargs = 0, desc = "Show OpenCode server status" })
    vim.api.nvim_create_user_command("OCServerStatus", function()
        opencode.ServerStatus()
    end, { nargs = 0, desc = "Show OpenCode server status" })

    vim.api.nvim_create_user_command("OpenCodeServerStart", function()
        opencode.ServerStart()
    end, { nargs = 0, desc = "Start OpenCode server" })
    vim.api.nvim_create_user_command("OCServerStart", function()
        opencode.ServerStart()
    end, { nargs = 0, desc = "Start OpenCode server" })

    vim.api.nvim_create_user_command("OpenCodeServerStop", function()
        opencode.ServerStop()
    end, { nargs = 0, desc = "Stop OpenCode server" })
    vim.api.nvim_create_user_command("OCServerStop", function()
        opencode.ServerStop()
    end, { nargs = 0, desc = "Stop OpenCode server" })

    vim.api.nvim_create_user_command("OpenCodeServerRestart", function()
        opencode.ServerRestart()
    end, { nargs = 0, desc = "Restart OpenCode server" })

    -- Fetch configuration from the OpenCode server
    vim.api.nvim_create_user_command("OCConfig", function(opts)
        local port = opencode.GetCurrentServerPort()
        if not port then
            vim.notify("OpenCode server is not running.", vim.log.levels.ERROR)
            return
        end

        local url = string.format("http://127.0.0.1:%s/config", port)
        local response = vim.fn.system({ "curl", "-s", url })

        if vim.v.shell_error ~= 0 then
            vim.notify(
                "Failed to fetch config from server. Please ensure the opencode server is running on port " .. port,
                vim.log.levels.ERROR)
            return
        end

        -- Create a new scratch buffer to display the config
        local buf = vim.api.nvim_create_buf(false, true) -- Create scratch buffer
        vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
        vim.api.nvim_buf_set_option(buf, "filetype", "json")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(response, "\n"))

        -- Open the buffer in a floating window
        local width = vim.o.columns
        local height = vim.o.lines
        local win_width = math.ceil(width * 0.8)
        local win_height = math.ceil(height * 0.8)
        local col = math.ceil((width - win_width) / 2)
        local row = math.ceil((height - win_height) / 2)
        vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            width = win_width,
            height = win_height,
            col = col,
            row = row,
            border = "rounded",
            style = "minimal",
        })
    end, {
        nargs = "?",
        desc = "Fetch and display OpenCode server configuration",
    })

    -- Agent management (build/plan)
    vim.api.nvim_create_user_command("OpenCodeAgent", function(opts)
        if opts.args and opts.args ~= "" then
            opencode.SetAgent(opts.args)
        else
            vim.notify("Current agent: " .. opencode.GetAgent(), vim.log.levels.INFO)
        end
    end, {
        nargs = "?",
        complete = function() return { "build", "plan" } end,
        desc = "Get or set OpenCode agent (build/plan)",
    })
    vim.api.nvim_create_user_command("OCAgent", function(opts)
        if opts.args and opts.args ~= "" then
            opencode.SetAgent(opts.args)
        else
            vim.notify("Current agent: " .. opencode.GetAgent(), vim.log.levels.INFO)
        end
    end, {
        nargs = "?",
        complete = function() return { "build", "plan" } end,
        desc = "Get or set OpenCode agent (build/plan)",
    })
end

-- =============================================================================
-- Keymap Definitions
-- =============================================================================

--- Setup default keymaps
---@param config CommandsConfig User configuration
local function setup_keymaps(config)
    if not config.keymaps.enable_default then
        return
    end

    local keymap = config.keymaps.open_prompt
    vim.keymap.set("n", keymap, "<Cmd>OpenCode<CR>", { noremap = true, silent = true, desc = "Open OpenCode prompt" })
    vim.keymap.set("v", keymap, "<Cmd>OpenCodeWSelection<CR>",
        { noremap = true, silent = true, desc = "Open OpenCode with selection" })
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Setup commands and keymaps
---@param opencode table The main opencode module
---@param config CommandsConfig User configuration
function M.setup(opencode, config)
    setup_commands(opencode)
    setup_keymaps(config)

    vim.api.nvim_create_user_command("OCConfig", function(opts)
        local port = opencode.GetCurrentServerPort()
        if not port then
            vim.notify("OpenCode server is not running.", vim.log.levels.ERROR)
            return
        end

        local url = string.format("http://127.0.0.1:%s/config", port)
        local response = vim.fn.system({ "curl", "-s", url })

        if vim.v.shell_error ~= 0 then
            vim.notify(
                "Failed to fetch config from server. Please ensure the opencode server is running on port " .. port,
                vim.log.levels.ERROR)
            return
        end

        -- Create a new scratch buffer to display the config
        local buf = vim.api.nvim_create_buf(false, true) -- Create scratch buffer
        vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
        vim.api.nvim_buf_set_option(buf, "filetype", "json")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(response, "\n"))

        -- Open the buffer in a floating window
        local width = vim.o.columns
        local height = vim.o.lines
        local win_width = math.ceil(width * 0.8)
        local win_height = math.ceil(height * 0.8)
        local col = math.ceil((width - win_width) / 2)
        local row = math.ceil((height - win_height) / 2)
        vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            width = win_width,
            height = win_height,
            col = col,
            row = row,
            border = "rounded",
            style = "minimal",
        })
    end, {
        nargs = "?",
        desc = "Fetch and display OpenCode server configuration",
    })
end

--- Get source file from current buffer (exported for use by other modules)
---@return string|nil
M.get_source_file = get_source_file

return M
