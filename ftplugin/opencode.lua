-- =============================================================================
-- Filetype plugin for opencode buffers
-- =============================================================================
-- Provides @ trigger for file search with fuzzy finder
-- Provides #buffer/#buf replacement with source file path

-- Prevent loading ftplugin multiple times for the same buffer
if vim.b.did_ftplugin_opencode then
    return
end
vim.b.did_ftplugin_opencode = true

-- =============================================================================
-- Helper Functions
-- =============================================================================

--- Insert file reference at cursor using Telescope file picker
local function insert_file_reference()
    local ok, builtin = pcall(require, "telescope.builtin")
    if not ok then
        vim.notify("telescope.nvim is required for file references", vim.log.levels.ERROR)
        return
    end

    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local target_buf = vim.api.nvim_get_current_buf()
    local target_win = vim.api.nvim_get_current_win()

    builtin.find_files({
        hidden = true,
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if not selection then
                    return
                end

                local filepath = selection[1] or selection.value
                if not filepath then
                    return
                end

                -- Validate target buffer and window still exist
                if not vim.api.nvim_buf_is_valid(target_buf) or not vim.api.nvim_win_is_valid(target_win) then
                    return
                end

                -- Insert the file path at cursor position with trailing space
                vim.api.nvim_set_current_win(target_win)
                local row, col = unpack(vim.api.nvim_win_get_cursor(target_win))
                local line = vim.api.nvim_buf_get_lines(target_buf, row - 1, row, false)[1]
                local new_line = line:sub(1, col) .. filepath .. " " .. line:sub(col + 1)
                vim.api.nvim_buf_set_lines(target_buf, row - 1, row, false, { new_line })
                vim.api.nvim_win_set_cursor(target_win, { row, col + #filepath + 1 })

                vim.schedule(function()
                    vim.cmd("startinsert!")
                end)
            end)
            return true
        end,
    })
end

--- Replace #buffer or #buf shortcuts with source file path
---@return boolean success Whether replacement occurred
local function try_replace_buffer_shortcut()
    local source_file = vim.b.opencode_source_file
    if not source_file or source_file == "" then
        return false
    end

    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local before_cursor = line:sub(1, col)

    -- Check for #buffer or #buf at end of text before cursor
    local pattern, replacement
    if before_cursor:match("#buffer$") then
        pattern = "#buffer$"
        replacement = "@" .. source_file
    elseif before_cursor:match("#buf$") then
        pattern = "#buf$"
        replacement = "@" .. source_file
    else
        return false
    end

    local new_before = before_cursor:gsub(pattern, replacement)
    local new_line = new_before .. line:sub(col + 1)
    vim.api.nvim_set_current_line(new_line)
    vim.api.nvim_win_set_cursor(0, { row, #new_before })
    return true
end

-- =============================================================================
-- Keymaps
-- =============================================================================

-- @ trigger: Insert file reference with fuzzy finder
vim.keymap.set("i", "@", function()
    -- Insert @ character first
    vim.api.nvim_feedkeys("@", "n", false)
    -- Then trigger the file finder asynchronously
    vim.schedule(function()
        insert_file_reference()
    end)
end, { buffer = true, noremap = true, silent = true, desc = "Insert file reference with fuzzy finder" })

-- Space trigger: Replace #buffer/#buf with source file path
vim.keymap.set("i", "<Space>", function()
    if try_replace_buffer_shortcut() then
        -- Replacement happened, add space after
        vim.api.nvim_feedkeys(" ", "n", false)
    else
        -- No replacement, just insert space
        vim.api.nvim_feedkeys(" ", "n", false)
    end
end, { buffer = true, noremap = true, silent = true, desc = "Replace #buffer/#buf with source file" })

-- =============================================================================
-- Buffer Options
-- =============================================================================

-- Enable word wrap for better editing experience
vim.opt_local.wrap = true
vim.opt_local.linebreak = true

-- Disable swap file for prompt buffers
vim.opt_local.swapfile = false

-- Set undo options
vim.opt_local.undofile = false
