local highlight = require("power-finder.highlight")

local LINKS = {
  PowerFinderNormal = "NormalFloat",
  PowerFinderBorder = "FloatBorder",
  PowerFinderTitle = "FloatTitle",
  PowerFinderFooter = "FloatFooter",
  PowerFinderCursorLine = "CursorLine",
  PowerFinderLabel = "Comment",
  PowerFinderPrompt = "Special",
  PowerFinderToggleOn = "PmenuSel",
  PowerFinderToggleCase = "WarningMsg",
  PowerFinderToggleOff = "Pmenu",
  PowerFinderStatus = "StatusLineNC",
  PowerFinderStatusNum = "Number",
  PowerFinderStatusScope = "Directory",
  PowerFinderStatusInfo = "DiagnosticInfo",
  PowerFinderError = "DiagnosticError",
  PowerFinderFile = "Directory",
  PowerFinderDisc = "Special",
  PowerFinderCount = "Comment",
  PowerFinderLineNr = "LineNr",
  PowerFinderMatch = "Search",
  PowerFinderGhost = "Comment",
  PowerFinderKey = "Special",
  PowerFinderKeyDesc = "Comment",
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

local function raw_hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = true, create = false })
end

local function effective_hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
end

local function reset_plugin_state()
  pcall(vim.api.nvim_del_augroup_by_name, "PowerFinderHighlights")
  for name, target in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { link = target })
  end
end

local function snapshot_hl(name)
  local value = vim.deepcopy(raw_hl(name))
  return function()
    vim.api.nvim_set_hl(0, name, {})
    if next(value) then
      vim.api.nvim_set_hl(0, name, value)
    end
  end
end

-- The local runner does not expose after_each, so guarantee cleanup even when
-- an assertion fails. Highlight definitions and autocmds are global to the
-- single Neovim process used by the entire suite.
local function isolated_it(name, fn)
  it(name, function()
    reset_plugin_state()
    local cleanups = {}
    local ok, err = xpcall(function()
      fn(function(cleanup)
        cleanups[#cleanups + 1] = cleanup
      end)
    end, debug.traceback)
    for i = #cleanups, 1, -1 do
      pcall(cleanups[i])
    end
    reset_plugin_state()
    if not ok then
      error(err, 0)
    end
  end)
end

describe("highlight", function()
  it("links every plugin group to a semantic colorscheme group", function()
    highlight.setup()
    for name, target in pairs(LINKS) do
      assert.equals(target, raw_hl(name).link)
    end
  end)

  isolated_it("follows target attributes without another setup call", function(defer)
    defer(snapshot_hl("NormalFloat"))
    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0x123456, italic = true, ctermfg = 2 })
    highlight.setup()

    local first = effective_hl("PowerFinderNormal")
    assert.equals(0x123456, first.fg)
    assert.equals(2, first.ctermfg)
    assert.is_true(first.italic)
    assert.is_nil(first.bg) -- transparent themes must stay transparent

    vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xABCDEF, bg = 0x010203, reverse = true, ctermfg = 5 })
    local second = effective_hl("PowerFinderNormal")
    assert.equals(0xABCDEF, second.fg)
    assert.equals(0x010203, second.bg)
    assert.equals(5, second.ctermfg)
    assert.is_true(second.reverse)
  end)

  isolated_it("keeps effective highlights in sync across colorscheme changes", function(defer)
    local previous = vim.g.colors_name
    defer(function()
      vim.cmd.colorscheme(previous or "default")
      if not previous then
        vim.g.colors_name = nil
      end
    end)
    highlight.setup()

    vim.cmd.colorscheme("morning")
    assert.equals("Search", raw_hl("PowerFinderMatch").link)
    assert.same(effective_hl("Search"), effective_hl("PowerFinderMatch"))

    vim.cmd.colorscheme("habamax")
    assert.equals("Search", raw_hl("PowerFinderMatch").link)
    assert.same(effective_hl("Search"), effective_hl("PowerFinderMatch"))
  end)

  isolated_it("registers one ColorScheme autocmd even when setup is repeated", function()
    highlight.setup()
    highlight.setup()
    local autocmds = vim.api.nvim_get_autocmds({
      event = "ColorScheme",
      group = "PowerFinderHighlights",
    })
    assert.equals(1, #autocmds)
  end)

  isolated_it("preserves colorscheme and user overrides", function(defer)
    vim.api.nvim_set_hl(0, "PowerFinderTitle", { fg = 0x654321, bold = true })
    highlight.setup()

    local title = raw_hl("PowerFinderTitle")
    assert.equals(0x654321, title.fg)
    assert.is_true(title.bold)
    assert.is_nil(title.link)

    local previous = vim.g.colors_name
    defer(function()
      vim.cmd.colorscheme(previous or "default")
      if not previous then
        vim.g.colors_name = nil
      end
    end)
    local user_group = vim.api.nvim_create_augroup("PowerFinderTestUserHighlights", { clear = true })
    defer(function()
      pcall(vim.api.nvim_del_augroup_by_id, user_group)
    end)
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = user_group,
      callback = function()
        vim.api.nvim_set_hl(0, "PowerFinderTitle", { fg = 0x654321, bold = true })
      end,
    })

    vim.cmd.colorscheme("habamax")
    title = raw_hl("PowerFinderTitle")
    assert.equals(0x654321, title.fg)
    assert.is_true(title.bold)
    assert.is_nil(title.link)
  end)
end)
