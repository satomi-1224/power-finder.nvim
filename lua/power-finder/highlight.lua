-- Highlight groups. Everything links to a standard group by default so the
-- plugin inherits the active colorscheme (Selenized and friends look right out
-- of the box); users may override any group before/after setup.
local M = {}

M.groups = {
  PowerFinderLabel = { link = "Label" },
  PowerFinderMatch = { link = "IncSearch" },
  PowerFinderFile = { link = "Directory" },
  PowerFinderCount = { link = "Comment" },
  PowerFinderLineNr = { link = "LineNr" },
  PowerFinderStatus = { link = "Comment" },
  PowerFinderToggleOn = { link = "String" },
  PowerFinderToggleOff = { link = "Comment" },
  PowerFinderScopeOn = { link = "Special" },
  PowerFinderDiffAdd = { link = "DiffAdd" },
  PowerFinderDiffDelete = { link = "DiffDelete" },
  PowerFinderSelected = { link = "Statement" },
  PowerFinderDeselected = { link = "Comment" },
}

function M.setup()
  for name, val in pairs(M.groups) do
    -- default = true: don't clobber a group the user already defined.
    local ok_existing = pcall(vim.api.nvim_get_hl, 0, { name = name })
    local defined = ok_existing and next(vim.api.nvim_get_hl(0, { name = name, link = false })) ~= nil
    if not defined then
      vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", { default = true }, val))
    end
  end
end

return M
