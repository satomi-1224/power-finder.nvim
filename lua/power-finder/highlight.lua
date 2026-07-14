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

-- Resolve a highlight group's effective attributes (links followed).
local function get_hl(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return (ok and h) or {}
end

function M.setup()
  local dark = vim.o.background ~= "light"
  local pal = dark and PALETTE.dark or PALETTE.light

  -- Pull each semantic color from the ACTIVE colorscheme's standard groups so
  -- the panel matches whatever theme is loaded; fall back to the Selenized
  -- palette only when a group is undefined (issue #3).
  local function pick(attr, names, fallback)
    for _, n in ipairs(names) do
      local c = get_hl(n)[attr]
      if c then
        return hl_hex(c)
      end
    end
    return fallback
  end

  local normal = get_hl("Normal")
  -- Panel ground: prefer the colorscheme's Normal bg so the panel blends in;
  -- fall back to the Selenized ground when Normal is transparent.
  local base = hl_hex(normal.bg) or pal.bg
  local fg = hl_hex(normal.fg) or pal.fg

  local accent = pick("fg", { "Function", "Identifier", "Statement", "Keyword", "Special", "Directory" }, pal.accent)
  local faint = pick("fg", { "Comment", "NonText", "LineNr" }, pal.faint)
  local dim = pick("fg", { "Comment", "Conceal" }, pal.dim)
  local add = pick("fg", { "diffAdded", "Added", "GitSignsAdd", "String", "DiffAdd" }, pal.add)
  local del = pick("fg", { "diffRemoved", "Removed", "GitSignsDelete", "Error", "ErrorMsg", "DiffDelete" }, pal.del)
  local info = pick("fg", { "Type", "Special" }, pal.info)

  -- Match highlight: reuse the colorscheme's incremental-search look when it
  -- has one (that is exactly "a search match"), else tint the accent.
  local inc = get_hl("IncSearch")
  if not (inc.fg or inc.bg) then
    inc = get_hl("Search")
  end

  -- Diff row backgrounds: reuse DiffAdd/DiffDelete bg if the theme sets one.
  local diff_add = get_hl("DiffAdd")
  local diff_del = get_hl("DiffDelete")

  -- The surface tiers used across the panel (panel < status < selection).
  local panel = dark and shade(base, 9) or shade(base, -5)
  local status = dark and shade(base, 17) or shade(base, -10)
  local sel = dark and shade(base, 26) or shade(base, -15)
  local chip = dark and shade(base, 22) or shade(base, -12)

  local add_bg = hl_hex(diff_add.bg) or blend(add, panel, 0.16)
  local del_bg = hl_hex(diff_del.bg) or blend(del, panel, 0.16)
  local match_fg = hl_hex(inc.fg) or accent
  local match_bg = hl_hex(inc.bg) or blend(accent, panel, 0.22)

  local groups = {
    -- window chrome ------------------------------------------------------
    PowerFinderNormal = { fg = fg, bg = panel },
    PowerFinderBorder = { fg = dark and shade(faint, -8) or shade(faint, 6), bg = panel },
    PowerFinderTitle = { fg = accent, bg = panel, bold = true },
    PowerFinderFooter = { fg = faint, bg = panel },
    PowerFinderCursorLine = { bg = sel },

    -- form ---------------------------------------------------------------
    PowerFinderLabel = { fg = faint, bg = panel },
    PowerFinderPrompt = { fg = accent, bg = panel, bold = true },

    -- toggle chips (.* / Aa / W) -----------------------------------------
    PowerFinderToggleOn = { fg = base, bg = accent, bold = true },
    PowerFinderToggleCase = { fg = base, bg = pal.warn, bold = true },
    PowerFinderToggleOff = { fg = faint, bg = chip },

    -- status line --------------------------------------------------------
    PowerFinderStatus = { fg = dim, bg = status },
    PowerFinderStatusNum = { fg = fg, bg = status, bold = true },
    PowerFinderStatusScope = { fg = accent, bg = status, bold = true },
    PowerFinderStatusInfo = { fg = info, bg = status },
    PowerFinderError = { fg = del, bg = status, bold = true },

    -- results ------------------------------------------------------------
    PowerFinderFile = { fg = fg, bg = panel, bold = true },
    PowerFinderDisc = { fg = accent, bg = panel },
    PowerFinderCount = { fg = faint, bg = panel },
    PowerFinderLineNr = { fg = faint, bg = panel },
    PowerFinderMatch = { fg = match_fg, bg = match_bg, bold = true },
    PowerFinderGhost = { fg = faint, bg = panel, italic = true },

    -- keybar (footer) ----------------------------------------------------
    PowerFinderKey = { fg = accent, bg = panel, bold = true },
    PowerFinderKeyDesc = { fg = faint, bg = panel },

    -- replace preview ----------------------------------------------------
    PowerFinderReplaceFrom = { fg = del, bg = panel, bold = true },
    PowerFinderReplaceTo = { fg = add, bg = panel, bold = true },
    PowerFinderDiffAdd = { fg = fg, bg = add_bg },
    PowerFinderDiffDelete = { fg = fg, bg = del_bg },
    PowerFinderDiffAddSign = { fg = add, bg = add_bg, bold = true },
    PowerFinderDiffDelSign = { fg = del, bg = del_bg, bold = true },
    PowerFinderSelected = { fg = add, bg = panel, bold = true },
    PowerFinderDeselected = { fg = faint, bg = panel },
    PowerFinderCheckbox = { fg = add, bg = panel, bold = true },
    PowerFinderCheckboxOff = { fg = faint, bg = panel },
  }

  for name, val in pairs(groups) do
    vim.api.nvim_set_hl(0, name, val)
  end
end

return M
