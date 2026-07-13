-- Public entry point for power-finder.nvim.
local config = require("power-finder.config")

local M = {}

--- Configure the plugin. Safe to call with no arguments.
---@param opts? table  see config.defaults
function M.setup(opts)
  config.setup(opts)

  local hl = require("power-finder.highlight")
  hl.setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("PowerFinderHighlights", { clear = true }),
    callback = function()
      hl.setup()
    end,
  })

  if config.options.keymap then
    vim.keymap.set("n", config.options.keymap, function()
      M.open()
    end, { desc = "Power Finder" })
  end

  return M
end

--- Open the finder panel.
---@param opts? { query?:string, scope?:string, scope_paths?:string[], cwd?:string }
function M.open(opts)
  return require("power-finder.panel").open(opts)
end

--- Open pre-seeded with the word under the cursor.
function M.open_cword()
  return M.open({ query = vim.fn.expand("<cword>") })
end

--- Open pre-seeded with the current visual selection.
function M.open_visual()
  local save = vim.fn.getreg("v")
  vim.cmd('noautocmd normal! "vy')
  local sel = vim.fn.getreg("v")
  vim.fn.setreg("v", save)
  sel = (sel or ""):gsub("\n", " ")
  return M.open({ query = sel })
end

return M
