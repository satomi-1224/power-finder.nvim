-- Small pure helpers. No vim UI APIs here so this stays trivially testable.
local M = {}

--- Trim surrounding ASCII whitespace.
---@param s string?
---@return string
function M.trim(s)
  if s == nil then
    return ""
  end
  return (tostring(s):match("^%s*(.-)%s*$"))
end

--- Split a comma-separated field (e.g. an include/exclude glob field) into a
--- list of trimmed, non-empty entries. Commas separate; spaces are preserved
--- inside an entry because globs may legitimately contain them.
---@param s string?
---@return string[]
function M.split_csv(s)
  local out = {}
  if s == nil then
    return out
  end
  for part in tostring(s):gmatch("[^,]+") do
    local trimmed = M.trim(part)
    if trimmed ~= "" then
      out[#out + 1] = trimmed
    end
  end
  return out
end

--- Convert a byte column (0-based, as ripgrep reports) into the number of
--- display cells before it, so the UI can align a caret/highlight even with
--- multibyte text. `text` is the full line; `byte_col` is 0-based.
---@param text string
---@param byte_col integer
---@return integer
function M.byte_to_cell(text, byte_col)
  local slice = text:sub(1, byte_col)
  return vim.fn.strdisplaywidth(slice)
end

--- Shorten a path for display, keeping the tail (filename + a little context).
---@param path string
---@param max integer
---@return string
function M.shorten(path, max)
  if #path <= max then
    return path
  end
  return "…" .. path:sub(#path - max + 2)
end

return M
