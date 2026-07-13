-- Highlight groups for the finder panel.
--
-- The panel needs to look solid and intentional on ANY colorscheme: the old
-- version linked everything to dim standard groups (Comment/LineNr) and never
-- forced a background, so on a transparent/blended colorscheme the whole panel
-- washed out into the wallpaper. Here we derive an opaque, self-consistent
-- palette every time (also on :colorscheme changes): the panel background is
-- taken from the active `Normal` so it blends in, and the accent/diff colors
-- come from a Selenized-based palette that matches the project's design.
--
-- Everything is set unconditionally so the panel tracks colorscheme switches.
-- Users who want to override a group can do so from a ColorScheme autocmd, or
-- by wrapping require("power-finder.highlight").setup.
local M = {}

-- Selenized accent palette (matches mockup.html). Backgrounds are derived from
-- the live Normal group so only these hues are hard-coded.
local PALETTE = {
  dark = {
    bg = "#103c48",
    fg = "#adbcbc",
    dim = "#92a4a5",
    faint = "#72898f",
    accent = "#4695f7",
    add = "#75b938",
    del = "#fa5750",
    warn = "#dbb32d",
    info = "#41c7b9",
    violet = "#af88eb",
  },
  light = {
    bg = "#fbf3db",
    fg = "#3a4d53",
    dim = "#53676d",
    faint = "#7c8377",
    accent = "#0072d4",
    add = "#489100",
    del = "#d2212d",
    warn = "#ad8900",
    info = "#009c8f",
    violet = "#8762c6",
  },
}

local function to_rgb(n)
  return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

local function clamp(x)
  return math.max(0, math.min(255, math.floor(x + 0.5)))
end

local function to_hex(r, g, b)
  return string.format("#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
end

-- Lighten (pct > 0) or darken (pct < 0) a "#rrggbb" color.
local function shade(hex, pct)
  local r, g, b = to_rgb(tonumber(hex:sub(2), 16))
  local f = pct / 100
  local function adj(c)
    return f >= 0 and c + (255 - c) * f or c * (1 + f)
  end
  return to_hex(adj(r), adj(g), adj(b))
end

-- Alpha-composite `fg` over `bg` (used for tinted match / diff backgrounds).
local function blend(fg, bg, alpha)
  local fr, fg2, fb = to_rgb(tonumber(fg:sub(2), 16))
  local br, bg2, bb = to_rgb(tonumber(bg:sub(2), 16))
  return to_hex(fr * alpha + br * (1 - alpha), fg2 * alpha + bg2 * (1 - alpha), fb * alpha + bb * (1 - alpha))
end

local function hl_hex(int)
  return int and string.format("#%06x", int) or nil
end

function M.setup()
  local dark = vim.o.background ~= "light"
  local pal = dark and PALETTE.dark or PALETTE.light

  local normal = {}
  pcall(function()
    normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  end)
  -- Panel ground: prefer the colorscheme's Normal bg so the panel blends in;
  -- fall back to the Selenized ground when Normal is transparent.
  local base = hl_hex(normal.bg) or pal.bg
  local fg = hl_hex(normal.fg) or pal.fg
  -- The three surface tiers used across the panel (panel < status < selection).
  local panel = dark and shade(base, 9) or shade(base, -5)
  local status = dark and shade(base, 17) or shade(base, -10)
  local sel = dark and shade(base, 26) or shade(base, -15)
  local chip = dark and shade(base, 22) or shade(base, -12)

  local groups = {
    -- window chrome ------------------------------------------------------
    PowerFinderNormal = { fg = fg, bg = panel },
    PowerFinderBorder = { fg = dark and shade(pal.faint, -8) or shade(pal.faint, 6), bg = panel },
    PowerFinderTitle = { fg = pal.accent, bg = panel, bold = true },
    PowerFinderFooter = { fg = pal.faint, bg = panel },
    PowerFinderCursorLine = { bg = sel },

    -- form ---------------------------------------------------------------
    PowerFinderLabel = { fg = pal.faint, bg = panel },
    PowerFinderPrompt = { fg = pal.accent, bg = panel, bold = true },

    -- toggle chips (.* / Aa / W) -----------------------------------------
    PowerFinderToggleOn = { fg = base, bg = pal.accent, bold = true },
    PowerFinderToggleCase = { fg = base, bg = pal.warn, bold = true },
    PowerFinderToggleOff = { fg = pal.faint, bg = chip },

    -- status line --------------------------------------------------------
    PowerFinderStatus = { fg = pal.dim, bg = status },
    PowerFinderStatusNum = { fg = fg, bg = status, bold = true },
    PowerFinderStatusScope = { fg = pal.violet, bg = status, bold = true },
    PowerFinderStatusInfo = { fg = pal.info, bg = status },
    PowerFinderError = { fg = pal.del, bg = status, bold = true },

    -- results ------------------------------------------------------------
    PowerFinderFile = { fg = fg, bg = panel, bold = true },
    PowerFinderDisc = { fg = pal.accent, bg = panel },
    PowerFinderCount = { fg = pal.faint, bg = panel },
    PowerFinderLineNr = { fg = pal.faint, bg = panel },
    PowerFinderMatch = { fg = pal.accent, bg = blend(pal.accent, panel, 0.22), bold = true },
    PowerFinderGhost = { fg = pal.faint, bg = panel, italic = true },

    -- keybar (footer) ----------------------------------------------------
    PowerFinderKey = { fg = pal.accent, bg = panel, bold = true },
    PowerFinderKeyDesc = { fg = pal.faint, bg = panel },

    -- replace preview ----------------------------------------------------
    PowerFinderReplaceFrom = { fg = pal.del, bg = panel, bold = true },
    PowerFinderReplaceTo = { fg = pal.add, bg = panel, bold = true },
    PowerFinderDiffAdd = { fg = fg, bg = blend(pal.add, panel, 0.16) },
    PowerFinderDiffDelete = { fg = fg, bg = blend(pal.del, panel, 0.16) },
    PowerFinderDiffAddSign = { fg = pal.add, bg = blend(pal.add, panel, 0.16), bold = true },
    PowerFinderDiffDelSign = { fg = pal.del, bg = blend(pal.del, panel, 0.16), bold = true },
    PowerFinderSelected = { fg = pal.add, bg = panel, bold = true },
    PowerFinderDeselected = { fg = pal.faint, bg = panel },
    PowerFinderCheckbox = { fg = pal.add, bg = panel, bold = true },
    PowerFinderCheckboxOff = { fg = pal.faint, bg = panel },
  }

  for name, val in pairs(groups) do
    vim.api.nvim_set_hl(0, name, val)
  end
end

return M
