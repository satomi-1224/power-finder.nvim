-- Parse ripgrep's `--json` event stream into a grouped result model.
-- Depends only on vim.json.decode (available in headless Neovim), so it runs
-- under the plenary test harness without any UI.
local M = {}

---@class pf.Submatch
---@field start integer     0-based byte offset (inclusive)
---@field finish integer    0-based byte offset (exclusive)
---@field text string       matched text
---@field replacement? string  present when rg ran with --replace

---@class pf.Match
---@field lnum integer      1-based line number
---@field text string       full line text (trailing newline stripped)
---@field submatches pf.Submatch[]

---@class pf.File
---@field path string
---@field matches pf.Match[]
---@field collapsed boolean

---@class pf.Results
---@field files pf.File[]
---@field total integer     total submatch count kept
---@field truncated boolean hit the max_results cap
---@field elapsed_us? integer  rg self-reported elapsed (microseconds)

local function strip_nl(s)
  return (s:gsub("\r?\n$", ""))
end

-- rg encodes non-UTF8 fields as { bytes = "<base64>" }; keep the readable form.
local function field_text(x)
  if type(x) == "table" then
    return x.text or ""
  end
  return x or ""
end

--- @param lines string[]  each element is one line of rg --json output
--- @param opts? { max_results?: integer }
--- @return pf.Results
function M.parse(lines, opts)
  opts = opts or {}
  local max_results = opts.max_results or math.huge

  local files = {}
  local by_path = {}
  local total = 0
  local truncated = false
  local elapsed_us = nil

  local function ensure_file(path)
    local f = by_path[path]
    if not f then
      f = { path = path, matches = {}, collapsed = false }
      by_path[path] = f
      files[#files + 1] = f
    end
    return f
  end

  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == "table" and ev.type then
        local t = ev.type
        if t == "begin" then
          if not truncated then
            ensure_file(field_text(ev.data.path))
          end
        elseif t == "match" and not truncated then
          local d = ev.data
          local f = ensure_file(field_text(d.path))
          local subs = {}
          for _, sm in ipairs(d.submatches or {}) do
            subs[#subs + 1] = {
              start = sm.start,
              finish = sm["end"],
              text = field_text(sm.match),
              replacement = sm.replacement and field_text(sm.replacement) or nil,
            }
          end
          f.matches[#f.matches + 1] = {
            lnum = d.line_number,
            text = strip_nl(field_text(d.lines)),
            submatches = subs,
          }
          total = total + #subs
          if total >= max_results then
            truncated = true
          end
        elseif t == "summary" then
          local st = ev.data and ev.data.stats
          if st and st.elapsed then
            elapsed_us = math.floor((st.elapsed.nanos or 0) / 1000) + (st.elapsed.secs or 0) * 1000000
          end
        end
      end
    end
  end

  -- Drop files that had a begin but produced no matches.
  local out = {}
  for _, f in ipairs(files) do
    if #f.matches > 0 then
      out[#out + 1] = f
    end
  end

  return { files = out, total = total, truncated = truncated, elapsed_us = elapsed_us }
end

return M
