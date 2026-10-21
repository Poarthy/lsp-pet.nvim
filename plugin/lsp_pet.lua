-- Only registers the command; lua/lsp_pet is required on first use, so this costs nothing at startup.
if vim.g.loaded_lsp_pet then return end
vim.g.loaded_lsp_pet = true

vim.api.nvim_create_user_command("LspPetDemo", function(c)
  require("lsp_pet").demo(c.args ~= "" and c.args or nil)
end, {
  nargs = "?",
  complete = function() return { "spin", "dead" } end,
  desc = "Play the LSP pet's boot animation (default | spin | dead)",
})
