local M = {}

-- Get the directory where nvim was started from
local nvim_cwd = vim.fn.getcwd()

-- Config file path for storing model selection
local config_dir = vim.fn.stdpath("data") .. "/opencode"
local config_file = config_dir .. "/config.json"

-- Current selected model (nil means use default)
local selected_model = nil

-- Load saved model from config file
local function load_config()
    if vim.fn.filereadable(config_file) == 1 then
        local content = vim.fn.readfile(config_file)
        if #content > 0 then
            local ok, data = pcall(vim.json.decode, table.concat(content, "\n"))
            if ok and data and data.model then
                selected_model = data.model
            end
        end
    end
end

-- Save model to config file
local function save_config()
    vim.fn.mkdir(config_dir, "p")
    local data = { model = selected_model }
    vim.fn.writefile({ vim.json.encode(data) }, config_file)
end

-- Get current model display string
local function get_model_display()
    if selected_model and selected_model ~= "" then
        -- Show shortened model name (just the model part after /)
        local short = selected_model:match("/(.+)$") or selected_model
        return short
    end
    return "default"
end

-- Load config on startup
load_config()

-- Check if AGENTS.md exists in the nvim start directory
local function has_agents_md()
    return vim.fn.filereadable(nvim_cwd .. "/AGENTS.md") == 1
end

-- Initialize opencode in the directory (creates AGENTS.md)
local function init_opencode(callback)
    vim.fn.jobstart({ "opencode", "agent", "create" }, {
        cwd = nvim_cwd,
        on_exit = function(_, code)
            if callback then
                callback(code == 0)
            end
        end,
    })
end

-- Parse opencode JSON output and extract only assistant text (no thinking)
-- Returns: response_text, error_message, is_thinking
local function parse_opencode_response(json_lines)
    local response_parts = {}
    local error_message = nil
    local is_thinking = false

    for _, line in ipairs(json_lines) do
        if line and line ~= "" then
            local ok, data = pcall(vim.json.decode, line)
            if ok and data then
                -- Check for error responses
                if data.type == "error" and data.error then
                    local err = data.error
                    if err.data and err.data.message then
                        error_message = err.data.message
                    elseif err.message then
                        error_message = err.message
                    else
                        error_message = err.name or "Unknown error"
                    end
                -- Detect thinking events
                elseif data.type == "thinking" or (data.part and data.part.type == "thinking") then
                    is_thinking = true
                -- Look for text events from assistant (not thinking)
                elseif data.type == "text" and data.part and data.part.type == "text" then
                    is_thinking = false -- No longer thinking once text arrives
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

-- Loading spinner frames
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Run opencode with the given prompt and show response in a split
local function run_opencode(prompt)
    if not prompt or prompt == "" then
        return
    end

    -- Check if #plan is in the prompt to determine agent mode
    local agent = "build"
    if prompt:match("#plan") then
        agent = "plan"
        -- Remove #plan from the prompt
        prompt = prompt:gsub("#plan%s*", ""):gsub("%s*#plan", "")
    end

    -- Create response buffer and split window
    local response_buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("vsplit")
    local response_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(response_win, response_buf)

    vim.bo[response_buf].buftype = "nofile"
    vim.bo[response_buf].bufhidden = "wipe"
    vim.bo[response_buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(response_buf, "OpenCode Response")

    -- Build command with optional model
    local cmd = { "opencode", "run", "--agent", agent, "--format", "json" }
    if selected_model and selected_model ~= "" then
        table.insert(cmd, "--model")
        table.insert(cmd, selected_model)
    end
    table.insert(cmd, prompt)

    -- Build header lines showing command and query
    -- Replace newlines in command display to avoid breaking nvim_buf_set_lines
    local cmd_display = table.concat(cmd, " "):gsub("\n", "\\n")
    local header_lines = {
        "**Command:** `" .. cmd_display .. "`",
        "",
        "**Query:**",
    }
    -- Split prompt by newlines and add each line
    local prompt_lines = vim.split(prompt, "\n", { plain = true })
    for _, pline in ipairs(prompt_lines) do
        table.insert(header_lines, pline)
    end
    table.insert(header_lines, "")
    table.insert(header_lines, "---")
    table.insert(header_lines, "")

    -- Show loading message with spinner
    local model_info = selected_model and (" [" .. get_model_display() .. "]") or ""
    local loading_prefix = "Running opencode (" .. agent .. " mode)" .. model_info .. " "
    local spinner_idx = 1
    local loading_timer = nil
    local is_loading = true

    local function update_spinner()
        if is_loading and vim.api.nvim_buf_is_valid(response_buf) then
            vim.schedule(function()
                if is_loading and vim.api.nvim_buf_is_valid(response_buf) then
                    local display_lines = vim.deepcopy(header_lines)
                    table.insert(display_lines, loading_prefix .. spinner_frames[spinner_idx])
                    table.insert(display_lines, "")
                    vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
                    spinner_idx = (spinner_idx % #spinner_frames) + 1
                end
            end)
        end
    end

    -- Start spinner animation
    loading_timer = vim.loop.new_timer()
    loading_timer:start(0, 80, vim.schedule_wrap(update_spinner))

    local function stop_loading()
        is_loading = false
        if loading_timer then
            loading_timer:stop()
            loading_timer:close()
            loading_timer = nil
        end
    end

    local json_output = {}
    local stderr_output = {}
    local job_id = nil
    local timeout_timer = nil
    local timeout_seconds = 120 -- 2 minute timeout

    -- Function to update display with current state
    local function update_display()
        if not vim.api.nvim_buf_is_valid(response_buf) then
            return
        end
        local display_lines = vim.deepcopy(header_lines)

        if is_loading then
            table.insert(display_lines, loading_prefix .. spinner_frames[spinner_idx])
            table.insert(display_lines, "")
        end

        -- Show stderr in real-time if we have any
        if #stderr_output > 0 then
            if is_loading then
                table.insert(display_lines, "**stderr output (process still running):**")
            else
                table.insert(display_lines, "**stderr output:**")
            end
            table.insert(display_lines, "```")
            for _, stderr_line in ipairs(stderr_output) do
                table.insert(display_lines, stderr_line)
            end
            table.insert(display_lines, "```")
            table.insert(display_lines, "")
        end

        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
    end

    local function stop_timeout()
        if timeout_timer then
            timeout_timer:stop()
            timeout_timer:close()
            timeout_timer = nil
        end
    end

    local function handle_timeout()
        stop_loading()
        stop_timeout()
        -- Kill the job if still running
        if job_id then
            vim.fn.jobstop(job_id)
        end
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(response_buf) then
                local display_lines = vim.deepcopy(header_lines)
                table.insert(display_lines, "**Error:** Request timed out after " .. timeout_seconds .. " seconds")
                table.insert(display_lines, "")
                if #stderr_output > 0 then
                    table.insert(display_lines, "**stderr output:**")
                    table.insert(display_lines, "```")
                    for _, stderr_line in ipairs(stderr_output) do
                        table.insert(display_lines, stderr_line)
                    end
                    table.insert(display_lines, "```")
                end
                vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
            end
        end)
    end

    local function execute_opencode()
        -- Start timeout timer
        timeout_timer = vim.loop.new_timer()
        timeout_timer:start(timeout_seconds * 1000, 0, vim.schedule_wrap(handle_timeout))

        job_id = vim.fn.jobstart(cmd, {
            cwd = nvim_cwd,
            stdout_buffered = false,
            on_stdout = function(_, data)
                if data then
                    for _, line in ipairs(data) do
                        if line and line ~= "" then
                            stop_loading()
                            stop_timeout()
                            table.insert(json_output, line)
                            -- Parse incrementally and update buffer
                            local response, err = parse_opencode_response(json_output)
                            vim.schedule(function()
                                if vim.api.nvim_buf_is_valid(response_buf) then
                                    local display_lines = vim.deepcopy(header_lines)
                                    if err then
                                        table.insert(display_lines, "Error: " .. err)
                                    elseif response and response ~= "" then
                                        local response_lines = vim.split(response, "\n", { plain = true })
                                        for _, rline in ipairs(response_lines) do
                                            table.insert(display_lines, rline)
                                        end
                                    end
                                    vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
                                end
                            end)
                        end
                    end
                end
            end,
            on_stderr = function(_, data)
                if data then
                    for _, line in ipairs(data) do
                        if line and line ~= "" then
                            table.insert(stderr_output, line)
                            -- Update display to show stderr in real-time
                            vim.schedule(update_display)
                        end
                    end
                end
            end,
            on_exit = function(_, code)
                stop_loading()
                stop_timeout()
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(response_buf) then
                        local display_lines = vim.deepcopy(header_lines)
                        local response, err = parse_opencode_response(json_output)
                        if err then
                            table.insert(display_lines, "Error: " .. err)
                        elseif not response or response == "" then
                            if code ~= 0 then
                                table.insert(display_lines, "Error: opencode exited with code " .. code)
                                if #stderr_output > 0 then
                                    table.insert(display_lines, "")
                                    table.insert(display_lines, "**stderr output:**")
                                    table.insert(display_lines, "```")
                                    for _, stderr_line in ipairs(stderr_output) do
                                        table.insert(display_lines, stderr_line)
                                    end
                                    table.insert(display_lines, "```")
                                end
                            else
                                if #stderr_output > 0 then
                                    table.insert(display_lines, "No response received.")
                                    table.insert(display_lines, "")
                                    table.insert(display_lines, "**stderr output:**")
                                    table.insert(display_lines, "```")
                                    for _, stderr_line in ipairs(stderr_output) do
                                        table.insert(display_lines, stderr_line)
                                    end
                                    table.insert(display_lines, "```")
                                else
                                    table.insert(display_lines, "No response received.")
                                end
                            end
                        else
                            local response_lines = vim.split(response, "\n", { plain = true })
                            for _, rline in ipairs(response_lines) do
                                table.insert(display_lines, rline)
                            end
                        end
                        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
                    end
                end)
            end,
        })
    end

    -- Check if we need to init first
    if not has_agents_md() then
        init_opencode(function(success)
            vim.schedule(function()
                if success then
                    execute_opencode()
                else
                    stop_loading()
                    if vim.api.nvim_buf_is_valid(response_buf) then
                        local display_lines = vim.deepcopy(header_lines)
                        table.insert(display_lines, "Error: Failed to initialize opencode")
                        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
                    end
                end
            end)
        end)
    else
        execute_opencode()
    end
end

-- Generate window title based on current mode
local function get_window_title(content)
    local mode = "build"
    if content and content:match("#plan") then
        mode = "plan"
    end
    local model_str = get_model_display()
    return " OpenCode [" .. mode .. "] [" .. model_str .. "] "
end

-- Update floating window title
local function update_window_title(win, buf)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local content = table.concat(lines, "\n")
    local title = get_window_title(content)
    vim.api.nvim_win_set_config(win, { title = title, title_pos = "center" })
end

M.OpenCode = function(initial_prompt, filetype, source_file)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

    local width = 60
    local height = 10
    local buf = vim.api.nvim_create_buf(false, true)
    local initial_title = get_window_title(nil)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = (vim.o.columns - width) / 2,
        row = (vim.o.lines - height) / 2,
        style = "minimal",
        border = "rounded",
        title = initial_title,
        title_pos = "center",
    })

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "opencode"
    vim.api.nvim_buf_set_name(buf, "OpenCode Prompt")

    -- Store source file for #buffer replacement
    vim.b[buf].opencode_source_file = source_file

    local initial_lines = {}
    if initial_prompt then
        initial_lines = { "```" .. filetype }
        vim.list_extend(initial_lines, initial_prompt)
        vim.list_extend(initial_lines, { "```", "" })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
        vim.api.nvim_win_set_cursor(win, { #initial_lines, 0 })
    end

    vim.cmd("startinsert")

    -- Update title when buffer content changes
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = buf,
        callback = function()
            update_window_title(win, buf)
        end,
    })

    local function submit_prompt()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local content = table.concat(lines, "\n")
        -- Replace #buffer or #buf with source file path if available
        if source_file and source_file ~= "" then
            content = content:gsub("#buffer", "@" .. source_file)
            content = content:gsub("#buf", "@" .. source_file)
        end
        vim.api.nvim_win_close(win, true)
        if content and content ~= "" then
            run_opencode(content)
        end
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            submit_prompt()
        end,
    })

    vim.keymap.set("c", "wq", function()
        if vim.fn.getcmdtype() == ":" and vim.api.nvim_get_current_buf() == buf then
            submit_prompt()
            return ""
        end
        return "wq"
    end, { buffer = buf, expr = true })

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, noremap = true, silent = true })
end

local function get_source_file()
    local bufname = vim.fn.expand("%")
    local buftype = vim.bo.buftype
    local filetype = vim.bo.filetype
    -- Check if it's a real file (not netrw, oil, temp buffer, etc.)
    if bufname == "" or buftype ~= "" or filetype == "netrw" or filetype == "oil" then
        return nil
    end
    -- Check if file exists on disk
    if vim.fn.filereadable(bufname) == 0 then
        return nil
    end
    return bufname
end

-- Select model using Telescope
M.SelectModel = function()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    -- Get models list
    local models = {}
    local handle = io.popen("opencode models 2>&1")
    if handle then
        for line in handle:lines() do
            if line and line ~= "" then
                table.insert(models, line)
            end
        end
        handle:close()
    end

    -- Add "default" option at the beginning
    table.insert(models, 1, "(default - no model specified)")

    pickers.new({}, {
        prompt_title = "Select OpenCode Model",
        finder = finders.new_table({
            results = models,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local model = selection[1]
                    if model == "(default - no model specified)" then
                        selected_model = nil
                    else
                        selected_model = model
                    end
                    save_config()
                    vim.notify("OpenCode model set to: " .. get_model_display(), vim.log.levels.INFO)
                end
            end)
            return true
        end,
    }):find()
end

vim.api.nvim_create_user_command("OpenCode", function()
    local source_file = get_source_file()
    M.OpenCode(nil, nil, source_file)
end, { nargs = 0 })

vim.api.nvim_create_user_command("OpenCodeWSelection", function()
    local source_file = get_source_file()
    local mode = vim.fn.mode()
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        M.OpenCode(nil, nil, source_file)
        return
    end
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    local selection_lines = vim.fn.getregion(start_pos, end_pos, { type = mode })
    local filetype = vim.bo.filetype
    M.OpenCode(selection_lines, filetype, source_file)
end, { nargs = 0 })

vim.api.nvim_create_user_command("OpenCodeModel", function()
    M.SelectModel()
end, { nargs = 0 })

-- Run opencode with a slash command
local function run_opencode_command(command, args)
    -- Create response buffer and split window
    local response_buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("vsplit")
    local response_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(response_win, response_buf)

    vim.bo[response_buf].buftype = "nofile"
    vim.bo[response_buf].bufhidden = "wipe"
    vim.bo[response_buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(response_buf, "OpenCode Response")

    -- Show loading message
    local model_info = selected_model and (" [" .. get_model_display() .. "]") or ""
    local args_display = (args and args ~= "") and (" " .. args) or ""
    vim.api.nvim_buf_set_lines(response_buf, 0, -1, false,
        { "Running " .. command .. args_display .. model_info .. "...", "" })

    local json_output = {}

    local function execute_opencode()
        -- Build command
        local cmd = { "opencode", "run", "--command", command, "--format", "json" }
        if selected_model and selected_model ~= "" then
            table.insert(cmd, "--model")
            table.insert(cmd, selected_model)
        end
        if args and args ~= "" then
            table.insert(cmd, args)
        end

        vim.fn.jobstart(cmd, {
            cwd = nvim_cwd,
            stdout_buffered = false,
            on_stdout = function(_, data)
                if data then
                    for _, line in ipairs(data) do
                        if line and line ~= "" then
                            table.insert(json_output, line)
                            -- Parse incrementally and update buffer
                            local response, err = parse_opencode_response(json_output)
                            vim.schedule(function()
                                if vim.api.nvim_buf_is_valid(response_buf) then
                                    if err then
                                        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, { "Error: " .. err })
                                    elseif response and response ~= "" then
                                        local lines = vim.split(response, "\n", { plain = true })
                                        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, lines)
                                    end
                                end
                            end)
                        end
                    end
                end
            end,
            on_stderr = function(_, data)
                -- Ignore stderr
            end,
            on_exit = function(_, code)
                vim.schedule(function()
                    if vim.api.nvim_buf_is_valid(response_buf) then
                        local response, err = parse_opencode_response(json_output)
                        if err then
                            vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, { "Error: " .. err })
                        elseif not response or response == "" then
                            if code ~= 0 then
                                vim.api.nvim_buf_set_lines(response_buf, 0, -1, false,
                                    { "Error: opencode exited with code " .. code })
                            else
                                vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, { "No response received." })
                            end
                        else
                            local lines = vim.split(response, "\n", { plain = true })
                            vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, lines)
                        end
                    end
                end)
            end,
        })
    end

    -- Check if we need to init first
    if not has_agents_md() then
        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, { "Initializing opencode...", "" })
        init_opencode(function(success)
            vim.schedule(function()
                if success then
                    execute_opencode()
                else
                    if vim.api.nvim_buf_is_valid(response_buf) then
                        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false,
                            { "Error: Failed to initialize opencode" })
                    end
                end
            end)
        end)
    else
        execute_opencode()
    end
end

-- OpenCode Review command with input prompt
M.OpenCodeReview = function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

    local width = 60
    local height = 8
    local buf = vim.api.nvim_create_buf(false, true)
    local model_str = get_model_display()
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = (vim.o.columns - width) / 2,
        row = (vim.o.lines - height) / 2,
        style = "minimal",
        border = "rounded",
        title = " OpenCode Review [" .. model_str .. "] ",
        title_pos = "center",
    })

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "opencode"
    vim.api.nvim_buf_set_name(buf, "OpenCode Review")

    -- Set initial help text
    local help_lines = {
        "# Review target (leave empty for default):",
        "# Examples:",
        "#   HEAD~3        - last 3 commits",
        "#   abc123        - specific commit",
        "#   main..HEAD    - commits since main",
        "#   v1.0.0        - specific tag",
        "",
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, help_lines)
    vim.api.nvim_win_set_cursor(win, { #help_lines, 0 })

    vim.cmd("startinsert")

    local function submit_review()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- Filter out comment lines and empty lines to get the actual input
        local input_lines = {}
        for _, line in ipairs(lines) do
            if not line:match("^#") then
                table.insert(input_lines, line)
            end
        end
        local args = vim.trim(table.concat(input_lines, " "))
        vim.api.nvim_win_close(win, true)
        run_opencode_command("/review", args)
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            submit_review()
        end,
    })

    vim.keymap.set("c", "wq", function()
        if vim.fn.getcmdtype() == ":" and vim.api.nvim_get_current_buf() == buf then
            submit_review()
            return ""
        end
        return "wq"
    end, { buffer = buf, expr = true })

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, noremap = true, silent = true })
end

vim.api.nvim_create_user_command("OpenCodeReview", function()
    M.OpenCodeReview()
end, { nargs = 0 })

vim.keymap.set("n", "<leader>oc", "<Cmd>OpenCode<CR>", { noremap = true, silent = true })
vim.keymap.set("v", "<leader>oc", "<Cmd>OpenCodeWSelection<CR>", { noremap = true, silent = true })
