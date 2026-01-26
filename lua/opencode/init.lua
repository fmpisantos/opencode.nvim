local M = {}

-- =============================================================================
-- OpenCode.nvim - Main Module
-- =============================================================================
-- A Neovim plugin for integrating the opencode CLI tool
-- This is the main entry point that coordinates all other modules

-- =============================================================================
-- Module Imports
-- =============================================================================

local config = require("opencode.config")
local utils = require("opencode.utils")
local ui = require("opencode.ui")
local session = require("opencode.session")
local server = require("opencode.server")
local requests = require("opencode.requests")
local runner = require("opencode.runner")

-- =============================================================================
-- Prompt Window
-- =============================================================================

-- Forward declaration for session picker
local select_session_for_prompt

--- Open the main prompt window
---@param initial_prompt? table Initial prompt lines (from visual selection)
---@param filetype? string Filetype for code fence
---@param source_file? string Source file path
---@param session_id_to_continue? string Session ID to continue (from picker or response buffer)
function M.OpenCode(initial_prompt, filetype, source_file, session_id_to_continue)
    local state = config.state

    -- Check if we're opening from a response buffer - get its session id
    local from_response_session = session.get_session_from_current_buffer()
    local session_to_use = session_id_to_continue or from_response_session

    -- Load session settings immediately if we have a session
    -- This ensures the prompt window title and state are correct from the start
    if session_to_use then
        local settings = session.get_session_settings(session_to_use)
        if settings.mode then
            config.state.mode = settings.mode
        end
        if settings.agent then
            config.state.current_agent = settings.agent
        end
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

    -- Clear session state (we'll use #session(<id>) in the prompt instead)
    session.clear_session()

    -- Check if we have an existing prompt buffer that's valid and displayed in a non-floating window
    local reuse_existing_buffer = false

    -- Recover prompt_buf if module state was lost but buffer still exists (e.g., after plugin reload)
    if not state.prompt_buf or not vim.api.nvim_buf_is_valid(state.prompt_buf) then
        local existing_buf = vim.fn.bufnr("opencode://prompt")
        if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
            state.prompt_buf = existing_buf
        end
    end

    if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
        local wins = vim.fn.win_findbuf(state.prompt_buf)
        for _, w in ipairs(wins) do
            local win_config = vim.api.nvim_win_get_config(w)
            if win_config.relative == "" then
                -- Buffer is displayed in a regular (non-floating) window
                -- Close that window and open in floating mode
                vim.api.nvim_win_close(w, false)
            end
        end
        -- Reuse the buffer if it has content and no initial_prompt is provided
        if not initial_prompt then
            local lines = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, -1, false)
            local has_content = vim.iter(lines):any(function(line) return line ~= "" end)
            if has_content then
                reuse_existing_buffer = true
            end
        end
    end

    local buf, win

    if reuse_existing_buffer and state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
        -- Reuse existing buffer, just create new floating window
        buf = state.prompt_buf
        win = vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            width = state.user_config.prompt_window.width,
            height = state.user_config.prompt_window.height,
            col = (vim.o.columns - state.user_config.prompt_window.width) / 2,
            row = (vim.o.lines - state.user_config.prompt_window.height) / 2,
            style = "minimal",
            border = "rounded",
            title = ui.get_window_title(nil, session_to_use),
            title_pos = "center",
        })
    else
        -- Delete any existing prompt buffer to avoid "buffer already exists" errors
        -- This includes the recovered prompt_buf and any buffer with the same name
        if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
            -- Set bufhidden to wipe before deletion to ensure it's fully removed
            pcall(function() vim.bo[state.prompt_buf].bufhidden = "wipe" end)
            pcall(vim.api.nvim_buf_delete, state.prompt_buf, { force = true })
            state.prompt_buf = nil
        end
        -- Also check by name in case prompt_buf wasn't set but buffer exists
        local existing_buf = vim.fn.bufnr("opencode://prompt")
        if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
            -- Set bufhidden to wipe before deletion to ensure it's fully removed
            pcall(function() vim.bo[existing_buf].bufhidden = "wipe" end)
            pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
        end

        -- Create new buffer and window
        buf = vim.api.nvim_create_buf(false, true)
        win = vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            width = state.user_config.prompt_window.width,
            height = state.user_config.prompt_window.height,
            col = (vim.o.columns - state.user_config.prompt_window.width) / 2,
            row = (vim.o.lines - state.user_config.prompt_window.height) / 2,
            style = "minimal",
            border = "rounded",
            title = ui.get_window_title(nil, session_to_use),
            title_pos = "center",
        })

        vim.bo[buf].buftype = "acwrite"
        vim.bo[buf].bufhidden = "hide" -- Changed from "wipe" to allow buffer reuse
        vim.bo[buf].filetype = "opencode"
        vim.bo[buf].swapfile = false -- Prevent swap file creation
        vim.bo[buf].buflisted = false -- Don't show in buffer list
        -- Use URI scheme to prevent Neovim from treating this as a file path
        -- Check if name is available first to avoid E95 error
        local name_buf = vim.fn.bufnr("opencode://prompt")
        if name_buf == -1 or not vim.api.nvim_buf_is_valid(name_buf) then
            vim.api.nvim_buf_set_name(buf, "opencode://prompt")
        else
            -- If another buffer still has this name (shouldn't happen), use a unique name
            vim.api.nvim_buf_set_name(buf, "opencode://prompt-" .. buf)
        end

    end

    -- Track prompt buffer and window in module state
    state.prompt_buf = buf
    state.prompt_win = win

    vim.b[buf].opencode_source_file = source_file

    -- Setup initial content (only if not reusing existing buffer)
    if not reuse_existing_buffer then
        if initial_prompt then
            state.draft_content = nil
            state.draft_cursor = nil
            local initial_lines = {}
            -- Add session reference if continuing a session
            if session_to_use then
                table.insert(initial_lines, "#session(" .. session_to_use .. ")")
            end
            -- Add #buffer reference if we have a source file
            if source_file and source_file ~= "" then
                table.insert(initial_lines, "#buffer")
            end
            table.insert(initial_lines, "```" .. filetype)
            vim.list_extend(initial_lines, initial_prompt)
            vim.list_extend(initial_lines, { "```", "" })
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
            vim.api.nvim_win_set_cursor(win, { #initial_lines, 0 })
        elseif state.draft_content then
            -- If we have draft content but need to add session reference
            local lines_to_set = vim.deepcopy(state.draft_content)
            if session_to_use and not utils.has_session_reference(table.concat(lines_to_set, "\n")) then
                table.insert(lines_to_set, 1, "#session(" .. session_to_use .. ")")
            end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines_to_set)
            if state.draft_cursor then
                -- Adjust cursor if we inserted a session line
                local row_offset = (session_to_use and not utils.has_session_reference(table.concat(state.draft_content, "\n"))) and 1 or
                    0
                pcall(vim.api.nvim_win_set_cursor, win, { state.draft_cursor[1] + row_offset, state.draft_cursor[2] })
            end
        elseif session_to_use then
            -- No draft, but we need to add session reference
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#session(" .. session_to_use .. ")", "" })
            vim.api.nvim_win_set_cursor(win, { 2, 0 })
        end
    end

    vim.cmd("startinsert")

    -- Clear existing autocmds for this buffer to prevent duplicates
    local augroup_name = "OpenCodePrompt_" .. buf
    vim.api.nvim_create_augroup(augroup_name, { clear = true })

    -- Update title on content change and handle #session trigger
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = augroup_name,
        buffer = buf,
        callback = function()
            -- Use prompt_win instead of captured win to get current window
            if not state.prompt_win or not vim.api.nvim_win_is_valid(state.prompt_win) then
                return
            end

            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local content = table.concat(lines, "\n")

            -- Check for #session trigger (without parentheses - user wants to pick a session)
            if content:match("#session%s*$") or content:match("#session[%s\n]") then
                -- But not if it already has session id: #session(...)
                if not content:match("#session%(") then
                    -- Remove #session from content
                    local new_lines = {}
                    for _, line in ipairs(lines) do
                        local new_line = line:gsub("#session%s*$", ""):gsub("#session([%s\n])", "%1")
                        table.insert(new_lines, new_line)
                    end
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)

                    -- Save current draft
                    local cursor_pos = vim.api.nvim_win_get_cursor(state.prompt_win)
                    state.draft_content = new_lines
                    state.draft_cursor = cursor_pos

                    -- Mark buffer as not modified to prevent "No write since last change" warning
                    vim.bo[buf].modified = false

                    -- Close prompt window and open session picker
                    vim.api.nvim_win_close(state.prompt_win, false)
                    state.prompt_win = nil
                    select_session_for_prompt(source_file)
                    return
                end
            end

            -- Update title - show session info if content has #session(<id>)
            -- Only update if it's a floating window (has relative set)
            local win_config = vim.api.nvim_win_get_config(state.prompt_win)
            if win_config.relative and win_config.relative ~= "" then
                -- Extract session id from content if present
                local session_in_content = content:match("#session%(([^)]+)%)")
                vim.api.nvim_win_set_config(state.prompt_win, {
                    title = ui.get_window_title(content, session_in_content),
                    title_pos = "center",
                })
            end
        end,
    })

    local function submit_prompt()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local content = table.concat(lines, "\n")

        -- Collect files to attach via --file flag
        local files_to_attach = {}

        -- If source_file is referenced via #buffer or #buf, add it to files
        if source_file and source_file ~= "" then
            if content:match("#buffer") or content:match("#buf") then
                table.insert(files_to_attach, source_file)
            end
            -- Replace #buffer/#buf with @filepath reference in the prompt text
            content = content:gsub("#buffer", "@" .. source_file):gsub("#buf", "@" .. source_file)
        end

        -- Remove bare #session triggers (but keep #session(<id>))
        content = content:gsub("#session%s*$", ""):gsub("#session([%s\n])", "%1")

        -- Check for session ID and load its settings
        local session_in_prompt = content:match("#session%(([^)]+)%)")
        local session_settings = {}
        if session_in_prompt then
            session_settings = session.get_session_settings(session_in_prompt)
        end

        -- Determine base mode and agent from session or current state
        -- Priority: Session Settings > Current State > Defaults
        local final_mode = session_settings.mode or config.get_project_mode()
        local final_agent = session_settings.agent or config.state.current_agent or config.state.user_config.agent or "build"

        -- Handle keywords for agent selection and mode switching iteratively
        -- This allows chaining commands like "agentic plan ..." or "plan agentic ..."
        local remaining_content, mode_override, agent_override = utils.parse_mode_agent_keywords(content)
        content = remaining_content
        
        -- Apply overrides if found
        if mode_override then final_mode = mode_override end
        if agent_override then final_agent = agent_override end

        -- Force update state and server sync before running
        -- This ensures we always use the correct settings even if they haven't "changed"
        -- 1. Update Mode
        if config.get_project_mode() ~= final_mode then
             config.set_project_mode(final_mode)
             vim.notify("Switched to " .. final_mode .. " mode", vim.log.levels.INFO)
        else
             -- Ensure state is consistent even if logic thinks it's the same
             config.state.mode = final_mode
        end

        -- 2. Update Agent
        config.state.current_agent = final_agent
        
        -- 3. Sync to Server (if in agentic mode)
        if final_mode == "agentic" then
            -- Force model sync
            server.set_server_model(config.state.selected_model)
            -- Force agent sync
            server.set_server_agent(final_agent)
            
            -- If we have a session ID, ensure it's synced too
            if session_in_prompt then
                server.set_server_session(session_in_prompt)
            end
        end

        -- Prepend agent keyword if it was an override, so runner sees it if needed
        -- (Though runner logic repeats some of this, passing it explicitly via state/server is safer)
        -- We'll explicitly handle the agent in runner.lua via state/server, but 
        -- we can also prepend the tag just in case runner relies on it for something specific.
        -- Actually, runner.lua checks for #plan/#build tags. 
        if agent_override == "plan" then
             content = "#plan " .. content
        elseif agent_override == "build" then
             content = "#build " .. content
        end

        state.draft_content = nil
        state.draft_cursor = nil

        -- Mark buffer as not modified to prevent "No write since last change" warning
        vim.bo[buf].modified = false

        -- Close any window displaying this buffer
        local wins = vim.fn.win_findbuf(buf)
        for _, w in ipairs(wins) do
            if vim.api.nvim_win_is_valid(w) then
                vim.api.nvim_win_close(w, false)
            end
        end
        state.prompt_win = nil

        -- Clear the prompt buffer content after submission
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
        end

        if content and vim.trim(content) ~= "" then
            runner.run_opencode(content, files_to_attach, source_file)
        end
    end

    local function save_draft_and_close()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local has_content = vim.iter(lines):any(function(line)
            return line ~= ""
        end)

        if has_content then
            state.draft_content = lines
            -- Get cursor from current window if it's displaying our buffer
            local current_win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_buf(current_win) == buf then
                state.draft_cursor = vim.api.nvim_win_get_cursor(current_win)
            end
        else
            state.draft_content = nil
            state.draft_cursor = nil
        end

        -- Mark buffer as not modified to prevent "No write since last change" warning
        vim.bo[buf].modified = false

        -- Close any window displaying this buffer
        local wins = vim.fn.win_findbuf(buf)
        for _, w in ipairs(wins) do
            if vim.api.nvim_win_is_valid(w) then
                vim.api.nvim_win_close(w, false)
            end
        end
        state.prompt_win = nil
    end

    local function attach_to_window()
        -- Close any floating windows displaying this buffer
        local wins = vim.fn.win_findbuf(buf)
        for _, w in ipairs(wins) do
            if vim.api.nvim_win_is_valid(w) then
                local win_config = vim.api.nvim_win_get_config(w)
                if win_config.relative and win_config.relative ~= "" then
                    vim.api.nvim_win_close(w, false)
                end
            end
        end
        state.prompt_win = nil

        -- Open the buffer in a new split window
        vim.cmd("split")
        local new_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(new_win, buf)

        -- Set window height to something reasonable
        vim.api.nvim_win_set_height(new_win, state.user_config.prompt_window.height + 5)

        vim.notify("Prompt attached to window. Use :OpenCode to return to floating mode.", vim.log.levels.INFO)
    end

    -- Keymaps and autocmds (add BufWriteCmd to the group)
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = augroup_name,
        buffer = buf,
        callback = submit_prompt,
    })

    -- Handle :wq and :x by using abbreviations that expand to :w
    vim.cmd(string.format("cnoreabbrev <buffer> wq w"))
    vim.cmd(string.format("cnoreabbrev <buffer> x w"))

    vim.keymap.set("n", "q", save_draft_and_close, { buffer = buf, noremap = true, silent = true })
    vim.keymap.set("n", "<Esc>", save_draft_and_close, { buffer = buf, noremap = true, silent = true })

    -- Submit prompt with Enter in normal mode (same as :w)
    vim.keymap.set("n", "<CR>", submit_prompt, { buffer = buf, noremap = true, silent = true, desc = "Submit prompt" })

    -- Keymap to attach floating window to a regular window
    vim.keymap.set({ "n", "i" }, "<C-x><C-e>", attach_to_window,
        { buffer = buf, noremap = true, silent = true, desc = "Attach prompt to window" })
    vim.keymap.set({ "n", "i" }, "<C-x>e", attach_to_window,
        { buffer = buf, noremap = true, silent = true, desc = "Attach prompt to window" })
end

-- =============================================================================
-- Review Window
-- =============================================================================

function M.OpenCodeReview()
    local state = config.state

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

    local buf, win = ui.create_floating_window({
        width = state.user_config.review_window.width,
        height = state.user_config.review_window.height,
        title = " OpenCode Review [" .. config.get_model_display() .. "] ",
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
        runner.run_opencode_command("review", args)
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = submit_review,
    })

    -- Handle :wq and :x by using abbreviations that expand to :w
    vim.cmd(string.format("cnoreabbrev <buffer> wq w"))
    vim.cmd(string.format("cnoreabbrev <buffer> x w"))

    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, noremap = true, silent = true })

    vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf, noremap = true, silent = true })

    -- Submit review with Enter in normal mode (same as :w)
    vim.keymap.set("n", "<CR>", submit_review, { buffer = buf, noremap = true, silent = true, desc = "Submit review" })
end

-- =============================================================================
-- Model Selection
-- =============================================================================

function M.SelectModel()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local state = config.state

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
                    state.selected_model = (model == "(default - no model specified)") and nil or model
                    config.save_config()
                    -- Sync model to running server in agentic mode
                    server.set_server_model(state.selected_model)
                    vim.notify("OpenCode model set to: " .. config.get_model_display(), vim.log.levels.INFO)
                end
            end)
            return true
        end,
    }):find()
end

-- =============================================================================
-- Session Selection
-- =============================================================================

--- Open session picker for viewing/continuing sessions
---@param callback? function Optional callback(session_id, session_name) after selection
---@param for_append? boolean If true, selected session will be used for appending
local function open_session_picker(callback, for_append)
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local state = config.state
    local sessions = session.list_sessions()

    -- Create entries with "New Session" at the top
    local entries = { { id = nil, display = config.NEW_SESSION_LABEL, name = nil } }
    for _, sess in ipairs(sessions) do
        table.insert(entries, sess)
    end

    pickers.new({}, {
        prompt_title = for_append and "Select Session to Continue" or "OpenCode Sessions",
        finder = finders.new_table({
            results = entries,
            entry_maker = function(entry)
                return {
                    value = entry,
                    display = entry.display,
                    ordinal = entry.display,
                }
            end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local entry = selection.value
                    if callback then
                        callback(entry.id, entry.name)
                    else
                        -- Default behavior: load session into response buffer
                        if entry.id then
                            -- Load existing session
                            state.current_session_id = entry.id
                            state.current_session_name = entry.name

                            -- Load session settings or fall back to defaults
                            local settings = session.get_session_settings(entry.id)
                            M.SetMode(settings.mode or config.defaults.mode or "quick")
                            M.SetAgent(settings.agent or "build")

                            local content = session.load_session(entry.id)
                            if content then
                                local buf, _ = ui.create_response_split("OpenCode Response", true)
                                vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
                                vim.notify("Loaded session: " .. (entry.name or entry.id), vim.log.levels.INFO)
                            end
                        else
                            -- New session selected
                            session.clear_session()
                            session.start_new_session()

                            -- Do NOT reset to defaults here. 
                            -- Keep the current mode/agent if the user has changed them via :OCMode or :OCAgent.
                            -- Defaults are handled by config.get_project_mode() and OpenCode() logic if state is nil.
                            
                            vim.notify("Started new session", vim.log.levels.INFO)
                        end
                    end
                end
            end)
            return true
        end,
    }):find()
end

--- Session picker specifically for prompt window (#session trigger)
---@param source_file? string Source file for the prompt
select_session_for_prompt = function(source_file)
    local state = config.state

    open_session_picker(function(session_id, session_name)
        if session_id then
            -- User selected an existing session - load it and open prompt with session reference
            local content = session.load_session(session_id)
            if content then
                -- Set current session so the response buffer gets the right id
                state.current_session_id = session_id
                state.current_session_name = session_name
                local buf, _ = ui.create_response_split("OpenCode Response", true)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
                vim.b[buf].opencode_session_id = session_id
            end
            -- Reopen prompt window with session id (will be inserted as #session(<id>))
            M.OpenCode(nil, nil, source_file, session_id)
        else
            -- User wants a new session - just reopen prompt without session reference
            M.OpenCode(nil, nil, source_file, nil)
        end
    end, true)
end

--- Public function to select sessions
function M.SelectSession()
    open_session_picker()
end

--- Toggle the response buffer (OpenCodeCLI)
function M.ToggleCLI()
    ui.toggle_response_buffer()
end

--- Attach the prompt floating window to a regular (non-floating) window
--- The buffer content will be the same, allowing editing in either window
function M.AttachWindow()
    local state = config.state

    -- Check if we have a valid prompt buffer
    if not state.prompt_buf or not vim.api.nvim_buf_is_valid(state.prompt_buf) then
        vim.notify("No OpenCode prompt window to attach", vim.log.levels.WARN)
        return
    end

    -- Close the floating window if it's open
    if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
        vim.api.nvim_win_close(state.prompt_win, false)
        state.prompt_win = nil
    end

    -- Open the buffer in a new split window
    vim.cmd("split")
    local new_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(new_win, state.prompt_buf)

    -- Set window height to something reasonable
    vim.api.nvim_win_set_height(new_win, state.user_config.prompt_window.height + 5)

    vim.notify("Prompt attached to window. Use :OpenCode to return to floating mode.", vim.log.levels.INFO)
end

--- Initialize opencode project (runs init command)
function M.Init()
    runner.run_opencode_command("init", nil)
end

--- Stop all active requests and servers
function M.StopAll()
    local request_count = requests.cancel_all_requests()
    local server_count = server.stop_all_servers()

    -- Also kill any stray processes with the fmpisantosOC- tag
    -- This satisfies: "user running OCStop ... can search for ... fmpisantosOC-<anything> and stop them"
    server.kill_all_tagged_servers()

    if request_count > 0 or server_count > 0 then
        local parts = {}
        if request_count > 0 then
            table.insert(parts, request_count .. " request(s)")
        end
        if server_count > 0 then
            table.insert(parts, server_count .. " server(s)")
        end
        vim.notify("Stopped " .. table.concat(parts, " and "), vim.log.levels.INFO)
    else
        vim.notify("No active requests or servers to stop", vim.log.levels.INFO)
    end
end

--- Get the number of active requests
---@return number
function M.GetActiveRequestCount()
    return requests.get_active_request_count()
end

-- =============================================================================
-- Mode Management
-- =============================================================================

--- Get the current project mode
---@return string mode "quick" or "agentic"
function M.GetMode()
    return config.get_project_mode()
end

--- Set the project mode
---@param mode? string "quick" or "agentic" (if nil, toggle)
function M.SetMode(mode)
    local current = config.get_project_mode()
    if not mode then
        -- Toggle
        mode = current == "quick" and "agentic" or "quick"
    end

    if config.set_project_mode(mode) then
        config.save_config()
        vim.notify("OpenCode mode set to: " .. mode, vim.log.levels.INFO)

        -- If switching to agentic mode and server is running, sync state
        if mode == "agentic" then
            local srv = server.get_server_for_cwd()
            if srv then
                -- Sync current global state to server
                server.sync_state_to_server()
            end
        end

        -- If switching away from agentic mode, optionally stop the server
        if mode == "quick" then
            local srv = server.get_server_for_cwd()
            if srv then
                vim.notify("Note: Server still running. Use :OCServerStop to stop it.", vim.log.levels.INFO)
            end
        end
    end
end

--- Get the current agent for the server
---@return string agent "build" or "plan"
function M.GetAgent()
    return server.get_server_agent()
end

--- Set the agent for the current server
--- Uses HTTP API to change the default_agent on the server when running
---@param agent string "build" or "plan"
function M.SetAgent(agent)
    if agent ~= "build" and agent ~= "plan" then
        vim.notify("Invalid agent: " .. tostring(agent) .. ". Use 'build' or 'plan'.", vim.log.levels.ERROR)
        return
    end

    -- Update local state
    config.state.current_agent = agent

    server.set_server_agent(agent, function(success, err)
        if success then
            vim.notify("OpenCode agent set to: " .. agent, vim.log.levels.INFO)
        else
            vim.notify("OpenCode agent set locally to: " .. agent .. " (server update failed: " .. tostring(err) .. ")", vim.log.levels.WARN)
        end
    end)
end

--- Get server status for current project
---@return table status { running, port, url, agent, model, session_id }
function M.GetServerStatus()
    local srv = server.get_server_for_cwd()
    if srv then
        return {
            running = true,
            port = srv.port,
            url = srv.url,
            agent = srv.agent,
            model = srv.model,
            session_id = srv.session_id,
        }
    end
    return { running = false }
end

--- Show server status
function M.ServerStatus()
    local srv = server.get_server_for_cwd()
    local mode = config.get_project_mode()

    if srv then
        local model_display = srv.model or "default"
        local session_display = srv.session_id and srv.session_id:sub(1, 15) or "none"
        vim.notify(string.format(
            "OpenCode Server Status:\n  Mode: %s\n  Status: Running\n  URL: %s\n  Port: %d\n  Agent: %s\n  Model: %s\n  Session: %s",
            mode, srv.url, srv.port, srv.agent or "build", model_display, session_display
        ), vim.log.levels.INFO)
    else
        vim.notify(string.format(
            "OpenCode Server Status:\n  Mode: %s\n  Status: Not running",
            mode
        ), vim.log.levels.INFO)
    end
end

--- Start the server for current project
function M.ServerStart()
    local srv = server.get_server_for_cwd()
    if srv then
        vim.notify("Server already running at " .. srv.url, vim.log.levels.INFO)
        return
    end

    vim.notify("Starting opencode server...", vim.log.levels.INFO)
    server.start_server_for_cwd(function(success, url_or_error)
        vim.schedule(function()
            if success then
                vim.notify("Server started at " .. url_or_error, vim.log.levels.INFO)
            else
                vim.notify("Failed to start server: " .. tostring(url_or_error), vim.log.levels.ERROR)
            end
        end)
    end)
end

--- Stop the server for current project
function M.ServerStop()
    if server.stop_server_for_cwd() then
        vim.notify("Server stopped", vim.log.levels.INFO)
    else
        vim.notify("No server running", vim.log.levels.INFO)
    end
end

--- Restart the server for current project
function M.ServerRestart()
    local was_running = server.stop_server_for_cwd()
    if was_running then
        vim.notify("Restarting opencode server...", vim.log.levels.INFO)
    else
        vim.notify("Starting opencode server...", vim.log.levels.INFO)
    end

    -- Small delay to ensure cleanup
    vim.defer_fn(function()
        server.start_server_for_cwd(function(success, url_or_error)
            vim.schedule(function()
                if success then
                    vim.notify("Server started at " .. url_or_error, vim.log.levels.INFO)
                else
                    vim.notify("Failed to start server: " .. tostring(url_or_error), vim.log.levels.ERROR)
                end
            end)
        end)
    end, 500)
end

-- =============================================================================
-- Setup
-- =============================================================================

--- Setup the opencode plugin
---@param opts? table User configuration options
function M.setup(opts)
    local state = config.state

    if state.is_initialized then
        return
    end

    -- Initialize configuration
    config.setup(opts)

    -- Initialize commands and keymaps via the commands module
    local commands = require("opencode.commands")
    commands.setup(M, state.user_config)
    ui.setup_auto_reload()

    -- Clean up opencode buffers before quit to prevent "No write since last change" errors
    -- QuitPre fires before Neovim checks for unsaved buffers
    vim.api.nvim_create_autocmd("QuitPre", {
        callback = function()
            -- Clean up prompt buffer
            if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
                vim.bo[state.prompt_buf].modified = false
            end
            -- Also check by name in case state was lost
            local prompt_buf = vim.fn.bufnr("opencode://prompt")
            if prompt_buf ~= -1 and vim.api.nvim_buf_is_valid(prompt_buf) then
                vim.bo[prompt_buf].modified = false
            end
        end,
    })

    -- Clean up active requests and servers when Vim exits
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            local request_count = requests.cancel_all_requests()
            -- Use force=true for immediate cleanup since Vim is exiting
            local server_count = server.stop_all_servers(true)
            if request_count > 0 or server_count > 0 then
                -- Brief message - Vim is exiting anyway
                local parts = {}
                if request_count > 0 then
                    table.insert(parts, request_count .. " request(s)")
                end
                if server_count > 0 then
                    table.insert(parts, server_count .. " server(s)")
                end
                print("OpenCode: Stopped " .. table.concat(parts, " and "))
            end
        end,
    })

    state.is_initialized = true
end

--- Export current cwd server port
---@return number|nil port
function M.GetCurrentServerPort()
    local srv = server.get_server_for_cwd()
    if srv then
        return srv.port
    end
    return nil
end

return M
