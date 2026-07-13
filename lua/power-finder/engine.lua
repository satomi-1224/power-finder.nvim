-- Pure translation of a query spec into a ripgrep argument vector.
-- Deliberately vim-free: callers resolve scope→paths and pass a plain table,
-- so this can be unit-tested exhaustively without any editor state.
local M = {}

---@class pf.Query
---@field query string           search pattern
---@field replace? string        replacement text (only used with with_replace)
---@field include_globs? string[] include globs, already split
---@field exclude_globs? string[] exclude globs, already split (no leading '!')
---@field paths? string[]        resolved search targets (dirs or files)
---@field regex? boolean         false => fixed-strings; nil/true => regex
---@field case? "smart"|"sensitive"|"ignore"  default "smart"
---@field word? boolean          whole-word match
---@field hidden? boolean        search hidden files
---@field no_ignore? boolean     ignore .gitignore et al.
---@field max_columns? integer   default 4096; <=0 disables

--- Build the ripgrep argv (without the leading "rg").
---@param q pf.Query
---@param opts? { with_replace?: boolean }
---@return string[]
function M.build_args(q, opts)
  opts = opts or {}
  local a = { "--json" }

  local case = q.case or "smart"
  if case == "smart" then
    a[#a + 1] = "--smart-case"
  elseif case == "sensitive" then
    a[#a + 1] = "--case-sensitive"
  elseif case == "ignore" then
    a[#a + 1] = "--ignore-case"
  else
    error("power-finder: unknown case mode: " .. tostring(case))
  end

  if q.word then
    a[#a + 1] = "--word-regexp"
  end
  if q.regex == false then
    a[#a + 1] = "--fixed-strings"
  end
  if q.hidden then
    a[#a + 1] = "--hidden"
  end
  if q.no_ignore then
    a[#a + 1] = "--no-ignore"
  end

  local maxcol = q.max_columns
  if maxcol == nil then
    maxcol = 4096
  end
  if maxcol and maxcol > 0 then
    a[#a + 1] = "--max-columns"
    a[#a + 1] = tostring(maxcol)
  end

  for _, g in ipairs(q.include_globs or {}) do
    a[#a + 1] = "--glob"
    a[#a + 1] = g
  end
  for _, g in ipairs(q.exclude_globs or {}) do
    a[#a + 1] = "--glob"
    a[#a + 1] = "!" .. g
  end

  if opts.with_replace then
    a[#a + 1] = "--replace"
    a[#a + 1] = q.replace or ""
  end

  -- Use -e/--regexp so a pattern that starts with '-' isn't taken as a flag.
  a[#a + 1] = "--regexp"
  a[#a + 1] = q.query or ""

  -- Guard search paths behind '--' so a path like "-foo" isn't a flag either.
  local paths = q.paths or {}
  if #paths > 0 then
    a[#a + 1] = "--"
    for _, p in ipairs(paths) do
      a[#a + 1] = p
    end
  end

  return a
end

return M
