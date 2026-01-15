-- =============================================================================
-- Filetype detection for OpenCode buffers
-- =============================================================================
-- This file handles automatic filetype detection for *.opencode files
-- Note: The main plugin sets filetype programmatically via vim.bo[buf].filetype
-- This detection is primarily for manual file editing scenarios

vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = "*.opencode",
    callback = function()
        vim.bo.filetype = "opencode"
    end,
    desc = "Detect opencode filetype for OpenCode prompt buffers",
})
