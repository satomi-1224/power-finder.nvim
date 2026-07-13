-- Minimal init used to run the test-suite in headless Neovim.
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"
-- It puts plenary and this plugin on the runtimepath, nothing else.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h") -- plugin root

vim.opt.runtimepath:append(root)
vim.opt.runtimepath:append(here .. "/deps/plenary.nvim")

-- Make `require("power-finder...")` resolve to lua/ of this repo.
vim.opt.packpath = {}

require("plenary.busted")
