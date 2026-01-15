local M = {}

-- =============================================================================
-- Constants
-- =============================================================================

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local TIMEOUT_MS = 120000 -- 2 minutes
local SPINNER_INTERVAL_MS = 80

-- =============================================================================
-- State
-- =============================================================================

local nvim_cwd = vim.fn.getcwd()
local config_dir = vim.fn.stdpath("data") .. "/opencode"
local config_file = config_dir .. "/config.json"
local selected_model = nil
local draft_content = nil
local draft_cursor = nil

-- =============================================================================
-- Config Management
-- =============================================================================

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

local function save_config()
    vim.fn.mkdir(config_dir, "p")
    local data = { model = selected_model }
    vim.fn.writefile({ vim.json.encode(data) }, config_file)
end

local function get_model_display()
    if selected_model and selected_model ~= "" then
        return selected_model:match("/(.+)$") or selected_model
    end
    return "default"
end

-- Load config on module load
load_config()

-- =============================================================================
-- Helper Functions
-- =============================================================================

local function has_agents_md()
    return vim.fn.filereadable(nvim_cwd .. "/AGENTS.md") == 1
end

local function init_opencode(callback)
    vim.system({ "opencode", "agent", "create" }, { cwd = nvim_cwd }, function(result)
        if callback then
            vim.schedule(function()
                callback(result.code == 0)
            end)
        end
    end)
end

--- Create a response buffer in a vertical split
---@param name string Buffer name
---@return number buf Buffer handle
---@return number win Window handle
local function create_response_split(name)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, name)

    return buf, win
end

--- Create a centered floating window
---@param opts { width: number, height: number, title: string, filetype: string, name: string }
---@return number buf Buffer handle
---@return number win Window handle
local function create_floating_window(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = opts.width,
        height = opts.height,
        col = (vim.o.columns - opts.width) / 2,
        row = (vim.o.lines - opts.height) / 2,
        style = "minimal",
        border = "rounded",
        title = opts.title,
        title_pos = "center",
    })

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = opts.filetype or "opencode"
    vim.api.nvim_buf_set_name(buf, opts.name)

    return buf, win
end

--- Append stderr output to display lines
---@param display_lines table Lines to append to
---@param stderr_output table Stderr lines
---@param is_running? boolean Whether process is still running
local function append_stderr_block(display_lines, stderr_output, is_running)
    if #stderr_output == 0 then
        return
    end

    table.insert(display_lines, "")
    if is_running then
        table.insert(display_lines, "**stderr output (process still running):**")
    else
        table.insert(display_lines, "**stderr output:**")
    end
    table.insert(display_lines, "```")
    for _, line in ipairs(stderr_output) do
        table.insert(display_lines, line)
    end
    table.insert(display_lines, "```")
end

--- Build opencode command with common options
---@param base_args table Base command arguments
---@param prompt? string Optional prompt to append
---@return table cmd Complete command
local function build_opencode_cmd(base_args, prompt)
    local cmd = vim.deepcopy(base_args)
    if selected_model and selected_model ~= "" then
        table.insert(cmd, "--model")
        table.insert(cmd, selected_model)
    end
    if prompt then
        table.insert(cmd, prompt)
    end
    return cmd
end

--- Parse lines from a string
---@param str string Input string
---@return table lines
local function parse_lines(str)
    local lines = {}
    if str and str ~= "" then
        for line in str:gmatch("[^\r\n]+") do
            table.insert(lines, line)
        end
    end
    return lines
end

-- =============================================================================
-- Response Parsing
-- =============================================================================

--- Parse opencode JSON output and extract assistant text
---@param json_lines table Lines of JSON output
---@return string|nil response Response text or nil
---@return string|nil error Error message or nil
---@return boolean is_thinking Whether model is thinking
local function parse_opencode_response(json_lines)
    local response_parts = {}
    local error_message = nil
    local is_thinking = false

    for _, line in ipairs(json_lines) do
        if line and line ~= "" then
            local ok, data = pcall(vim.json.decode, line)
            if ok and data then
                if data.type == "error" and data.error then
                    local err = data.error
                    error_message = err.data and err.data.message
                        or err.message
                        or err.name
                        or "Unknown error"
                elseif data.type == "thinking" or (data.part and data.part.type == "thinking") then
                    is_thinking = true
                elseif data.type == "text" and data.part and data.part.type == "text" then
                    is_thinking = false
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

-- =============================================================================
-- Spinner
-- =============================================================================

---@class Spinner
---@field private buf number
---@field private is_running boolean
---@field private timer number|nil
---@field private idx number
---@field private prefix string
---@field private header_lines table
local Spinner = {}
Spinner.__index = Spinner

---@param buf number Buffer handle
---@param prefix string Loading message prefix
---@param header_lines table Header lines to display
---@return Spinner
function Spinner.new(buf, prefix, header_lines)
    local self = setmetatable({}, Spinner)
    self.buf = buf
    self.is_running = true
    self.timer = nil
    self.idx = 1
    self.prefix = prefix
    self.header_lines = header_lines
    return self
end

function Spinner:start()
    local function update()
        if not self.is_running or not vim.api.nvim_buf_is_valid(self.buf) then
            return
        end

        local display_lines = vim.deepcopy(self.header_lines)
        table.insert(display_lines, self.prefix .. SPINNER_FRAMES[self.idx])
        table.insert(display_lines, "")
        vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, display_lines)

        self.idx = (self.idx % #SPINNER_FRAMES) + 1

        if self.is_running then
            self.timer = vim.fn.timer_start(SPINNER_INTERVAL_MS, function()
                update()
            end)
        end
    end

    self.timer = vim.fn.timer_start(0, function()
        update()
    end)
end

function Spinner:stop()
    self.is_running = false
    if self.timer then
        vim.fn.timer_stop(self.timer)
        self.timer = nil
    end
end

-- =============================================================================
-- Run OpenCode
-- =============================================================================

local function run_opencode(prompt)
    if not prompt or prompt == "" then
        return
    end

    -- Determine agent mode
    local agent = "build"
    if prompt:match("#plan") then
        agent = "plan"
        prompt = prompt:gsub("#plan%s*", ""):gsub("%s*#plan", "")
    end

    local response_buf = create_response_split("OpenCode Response")

    -- Build command
    local cmd = build_opencode_cmd(
        { "opencode", "run", "--agent", agent, "--format", "json" },
        prompt
    )

    -- Build header
    local cmd_display = table.concat(cmd, " "):gsub("\n", "\\n")
    local header_lines = {
        "**Command:** `" .. cmd_display .. "`",
        "",
        "**Query:**",
    }
    vim.list_extend(header_lines, vim.split(prompt, "\n", { plain = true }))
    vim.list_extend(header_lines, { "", "---", "" })

    -- Setup spinner
    local model_info = selected_model and (" [" .. get_model_display() .. "]") or ""
    local loading_prefix = "Running opencode (" .. agent .. " mode)" .. model_info .. " "
    local spinner = Spinner.new(response_buf, loading_prefix, header_lines)
    spinner:start()

    local json_output = {}
    local stderr_output = {}
    local system_obj = nil

    local function handle_timeout()
        vim.schedule(function()
            spinner:stop()
            if system_obj then
                system_obj:kill(9)
            end
            if vim.api.nvim_buf_is_valid(response_buf) then
                local display_lines = vim.deepcopy(header_lines)
                table.insert(display_lines, "**Error:** Request timed out after 120 seconds")
                append_stderr_block(display_lines, stderr_output)
                vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
            end
        end)
    end

    local function execute()
        vim.fn.timer_start(TIMEOUT_MS, function()
            handle_timeout()
        end)

        system_obj = vim.system(cmd, { cwd = nvim_cwd }, function(result)
            vim.schedule(function()
                spinner:stop()
                if not vim.api.nvim_buf_is_valid(response_buf) then
                    return
                end

                json_output = parse_lines(result.stdout)
                stderr_output = parse_lines(result.stderr)

                local display_lines = vim.deepcopy(header_lines)
                local response, err = parse_opencode_response(json_output)

                if err then
                    table.insert(display_lines, "**Error:** " .. err)
                    append_stderr_block(display_lines, stderr_output)
                elseif not response or response == "" then
                    if result.code ~= 0 then
                        table.insert(display_lines, "**Error:** opencode exited with code " .. result.code)
                        append_stderr_block(display_lines, stderr_output)
                    else
                        table.insert(display_lines, "No response received.")
                        append_stderr_block(display_lines, stderr_output)
                    end
                else
                    vim.list_extend(display_lines, vim.split(response, "\n", { plain = true }))
                end

                vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
            end)
        end)
    end

    -- Check if we need to init first
    if not has_agents_md() then
        init_opencode(function(success)
            if success then
                execute()
            else
                spinner:stop()
                if vim.api.nvim_buf_is_valid(response_buf) then
                    local display_lines = vim.deepcopy(header_lines)
                    table.insert(display_lines, "Error: Failed to initialize opencode")
                    vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, display_lines)
                end
            end
        end)
    else
        execute()
    end
end

-- =============================================================================
-- Run OpenCode Command (slash commands)
-- =============================================================================

local function run_opencode_command(command, args)
    local response_buf = create_response_split("OpenCode Response")

    -- Show loading message
    local model_info = selected_model and (" [" .. get_model_display() .. "]") or ""
    local args_display = (args and args ~= "") and (" " .. args) or ""
    vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, {
        "Running " .. command .. args_display .. model_info .. "...",
        "",
    })

    local function execute()
        local cmd = build_opencode_cmd(
            { "opencode", "run", "--command", command, "--format", "json" },
            (args and args ~= "") and args or nil
        )

        vim.system(cmd, { cwd = nvim_cwd }, function(result)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(response_buf) then
                    return
                end

                local json_output = parse_lines(result.stdout)
                local response, err = parse_opencode_response(json_output)

                if err then
                    vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, { "Error: " .. err })
                elseif not response or response == "" then
                    if result.code ~= 0 then
                        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, {
                            "Error: opencode exited with code " .. result.code,
                            "",
                            result.stderr or "",
                        })
                    else
                        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, { "No response received." })
                    end
                else
                    vim.api.nvim_buf_set_lines(response_buf, 0, -1, false,
                        vim.split(response, "\n", { plain = true }))
                end
            end)
        end)
    end

    if not has_agents_md() then
        vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, { "Initializing opencode...", "" })
        init_opencode(function(success)
            if success then
                execute()
            elseif vim.api.nvim_buf_is_valid(response_buf) then
                vim.api.nvim_buf_set_lines(response_buf, 0, -1, false, {
                    "Error: Failed to initialize opencode",
                })
            end
        end)
    else
        execute()
    end
end

-- =============================================================================
-- Prompt Window
-- =============================================================================

local function get_window_title(content)
    local mode = (content and content:match("#plan")) and "plan" or "build"
    return " OpenCode [" .. mode .. "] [" .. get_model_display() .. "] "
end

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
    return bufname
end

M.OpenCode = function(initial_prompt, filetype, source_file)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

    local buf, win = create_floating_window({
        width = 60,
        height = 10,
        title = get_window_title(nil),
        filetype = "opencode",
        name = "OpenCode Prompt",
    })

    vim.b[buf].opencode_source_file = source_file

    -- Setup initial content
    if initial_prompt then
        draft_content = nil
        draft_cursor = nil
        local initial_lines = { "```" .. filetype }
        vim.list_extend(initial_lines, initial_prompt)
        vim.list_extend(initial_lines, { "```", "" })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
        vim.api.nvim_win_set_cursor(win, { #initial_lines, 0 })
    elseif draft_content then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, draft_content)
        if draft_cursor then
            pcall(vim.api.nvim_win_set_cursor, win, draft_cursor)
        end
    end

    vim.cmd("startinsert")

    -- Update title on content change
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = buf,
        callback = function()
            if vim.api.nvim_win_is_valid(win) then
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                local content = table.concat(lines, "\n")
                vim.api.nvim_win_set_config(win, {
                    title = get_window_title(content),
                    title_pos = "center",
                })
            end
        end,
    })

    local function submit_prompt()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local content = table.concat(lines, "\n")

        if source_file and source_file ~= "" then
            content = content:gsub("#buffer", "@" .. source_file):gsub("#buf", "@" .. source_file)
        end

        draft_content = nil
        draft_cursor = nil
        vim.api.nvim_win_close(win, true)

        if content and content ~= "" then
            run_opencode(content)
        end
    end

    local function save_draft_and_close()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local has_content = vim.iter(lines):any(function(line)
            return line ~= ""
        end)

        if has_content then
            draft_content = lines
            draft_cursor = vim.api.nvim_win_get_cursor(win)
        else
            draft_content = nil
            draft_cursor = nil
        end
        vim.api.nvim_win_close(win, true)
    end

    -- Keymaps
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = submit_prompt,
    })

    vim.keymap.set("c", "wq", function()
        if vim.fn.getcmdtype() == ":" and vim.api.nvim_get_current_buf() == buf then
            submit_prompt()
            return ""
        end
        return "wq"
    end, { buffer = buf, expr = true })

    vim.keymap.set("n", "q", save_draft_and_close, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "<Esc>", save_draft_and_close, { buffer = buf, noremap = true, silent = true })
end

-- =============================================================================
-- Review Window
-- =============================================================================

M.OpenCodeReview = function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

    local buf, win = create_floating_window({
        width = 60,
        height = 8,
        title = " OpenCode Review [" .. get_model_display() .. "] ",
        filetype = "opencode",
        name = "OpenCode Review",
    })

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
        local input_lines = vim.iter(lines):filter(function(line)
            return not line:match("^#")
        end):totable()
        local args = vim.trim(table.concat(input_lines, " "))
        vim.api.nvim_win_close(win, true)
        run_opencode_command("/review", args)
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = submit_review,
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

-- =============================================================================
-- Model Selection
-- =============================================================================

M.SelectModel = function()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    -- Get models list synchronously
    local result = vim.system({ "opencode", "models" }, { text = true }):wait()
    local models = { "(default - no model specified)" }

    if result.stdout then
        for line in result.stdout:gmatch("[^\r\n]+") do
            if line ~= "" then
                table.insert(models, line)
            end
        end
    end

    pickers.new({}, {
        prompt_title = "Select OpenCode Model",
        finder = finders.new_table({ results = models }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local model = selection[1]
                    selected_model = (model == "(default - no model specified)") and nil or model
                    save_config()
                    vim.notify("OpenCode model set to: " .. get_model_display(), vim.log.levels.INFO)
                end
            end)
            return true
        end,
    }):find()
end

-- =============================================================================
-- Commands & Keymaps
-- =============================================================================

vim.api.nvim_create_user_command("OpenCode", function()
    M.OpenCode(nil, nil, get_source_file())
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
    M.OpenCode(selection_lines, vim.bo.filetype, source_file)
end, { nargs = 0 })

vim.api.nvim_create_user_command("OpenCodeModel", function()
    M.SelectModel()
end, { nargs = 0 })

vim.api.nvim_create_user_command("OpenCodeReview", function()
    M.OpenCodeReview()
end, { nargs = 0 })

vim.keymap.set("n", "<leader>oc", "<Cmd>OpenCode<CR>", { noremap = true, silent = true })
vim.keymap.set("v", "<leader>oc", "<Cmd>OpenCodeWSelection<CR>", { noremap = true, silent = true })

return M
