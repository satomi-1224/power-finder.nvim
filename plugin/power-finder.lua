-- Register the :PowerFinder command eagerly so it works even before setup().
-- All heavy modules are required lazily inside the callbacks.
if vim.g.loaded_power_finder then
  return
end
vim.g.loaded_power_finder = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("power-finder.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("PowerFinder", function(a)
  local query = a.args ~= "" and a.args or nil
  local scope = a.range > 0 and nil or nil -- reserved
  require("power-finder").open({ query = query })
end, { nargs = "?", desc = "Open Power Finder", range = true })

vim.api.nvim_create_user_command("PowerFinderCword", function()
  require("power-finder").open_cword()
end, { desc = "Power Finder: search word under cursor" })
