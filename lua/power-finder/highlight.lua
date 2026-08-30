-- Theme-native highlight groups for the finder panel.
--
-- Keep these as links instead of copying or deriving RGB values. Links retain
-- every attribute supplied by the active colorscheme (GUI/cterm colors,
-- reverse, blend, transparency, and styles) and continue to follow their
-- targets when the colorscheme changes them.
local M = {}

local LINKS = {
  -- window chrome
  PowerFinderNormal = "NormalFloat",
  PowerFinderBorder = "FloatBorder",
  PowerFinderTitle = "FloatTitle",
  PowerFinderFooter = "FloatFooter",
  PowerFinderCursorLine = "CursorLine",

  -- form
  PowerFinderLabel = "Comment",
  PowerFinderPrompt = "Special",

  -- toggle chips (.* / Aa / W)
  PowerFinderToggleOn = "PmenuSel",
  PowerFinderToggleCase = "WarningMsg",
  PowerFinderToggleOff = "Pmenu",

  -- status line
  PowerFinderStatus = "StatusLineNC",
  PowerFinderStatusNum = "Number",
  PowerFinderStatusScope = "Directory",
  PowerFinderStatusInfo = "DiagnosticInfo",
  PowerFinderError = "DiagnosticError",

  -- results
  PowerFinderFile = "Directory",
  PowerFinderDisc = "Special",
  PowerFinderCount = "Comment",
  PowerFinderLineNr = "LineNr",
  PowerFinderMatch = "Search",
  PowerFinderGhost = "Comment",

  -- keybar (footer)
  PowerFinderKey = "Special",
  PowerFinderKeyDesc = "Comment",

  -- replace preview
  PowerFinderReplaceFrom = "Removed",
  PowerFinderReplaceTo = "Added",
  PowerFinderDiffAdd = "DiffAdd",
  PowerFinderDiffDelete = "DiffDelete",
  PowerFinderDiffAddSign = "Added",
  PowerFinderDiffDelSign = "Removed",
  PowerFinderSelected = "Added",
  PowerFinderDeselected = "Comment",
  PowerFinderCheckbox = "Added",
  PowerFinderCheckboxOff = "Comment",
}

-- Restore links that a :colorscheme command may have cleared. `default` is
-- intentional: a colorscheme or user can define PowerFinder groups directly,
-- and those definitions must win over the plugin defaults.
function M.apply()
  for name, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("PowerFinderHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Restore power-finder theme highlight links",
    callback = M.apply,
  })
  M.apply()
end

return M
