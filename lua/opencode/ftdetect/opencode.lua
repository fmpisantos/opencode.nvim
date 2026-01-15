-- Detect opencode filetype for OpenCode prompt buffers
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = "*.opencode",
    callback = function()
        vim.bo.filetype = "opencode"
    end,
})
