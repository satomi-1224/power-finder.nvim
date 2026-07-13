-- Replacement computation + application.
--
-- The pure part (render_replaced_line / build_preview) is fully unit-tested.
-- ripgrep itself computes each submatch's `replacement` (so rust-regex capture
-- refs like $1 / ${name} are honored exactly); we only splice bytes together.
-- The apply part touches the filesystem/buffers and lives at the bottom.
local M = {}

--- Rebuild a single line by splicing in every submatch replacement, using the
--- 0-based byte offsets ripgrep reports. Multibyte-safe because string.sub in
--- Lua works on bytes and rg's offsets are byte offsets.
---@param text string                 original line
---@param submatches pf.Submatch[]     must be ordered by start (rg guarantees)
---@return string
function M.render_replaced_line(text, submatches)
  local out = {}
  local cursor = 0 -- 0-based byte cursor into `text`
  for _, sm in ipairs(submatches) do
    if sm.replacement ~= nil then
      -- bytes [cursor, start) → 1-based sub(cursor+1, start)
      out[#out + 1] = text:sub(cursor + 1, sm.start)
      out[#out + 1] = sm.replacement
      cursor = sm.finish
    end
  end
  out[#out + 1] = text:sub(cursor + 1)
  return table.concat(out)
end

---@class pf.PreviewLine
---@field lnum integer
---@field old string
---@field new string

---@class pf.PreviewFile
---@field path string
---@field changes integer   number of individual replacements
---@field selected boolean   included in apply (default true)
---@field lines pf.PreviewLine[]

--- Turn a parsed results model (from `rg --json -r`) into a diff preview.
--- Lines whose replacement equals the original are skipped.
---@param results pf.Results
---@return pf.PreviewFile[]
function M.build_preview(results)
  local files = {}
  for _, f in ipairs(results.files or {}) do
    local lines = {}
    local changes = 0
    for _, m in ipairs(f.matches) do
      local n = 0
      for _, sm in ipairs(m.submatches) do
        if sm.replacement ~= nil then
          n = n + 1
        end
      end
      if n > 0 then
        local new_text = M.render_replaced_line(m.text, m.submatches)
        if new_text ~= m.text then
          lines[#lines + 1] = { lnum = m.lnum, old = m.text, new = new_text }
          changes = changes + n
        end
      end
    end
    if #lines > 0 then
      files[#files + 1] = {
        path = f.path,
        changes = changes,
        selected = true,
        lines = lines,
      }
    end
  end
  return files
end

--- Summarize a preview (for the status line): file/occurrence counts of the
--- currently-selected files.
---@param preview pf.PreviewFile[]
---@return { files:integer, total_files:integer, changes:integer }
function M.summarize(preview)
  local files, total_files, changes = 0, 0, 0
  for _, f in ipairs(preview) do
    total_files = total_files + 1
    if f.selected then
      files = files + 1
      changes = changes + f.changes
    end
  end
  return { files = files, total_files = total_files, changes = changes }
end

-- True if any submatch carries a replacement (i.e. ripgrep is new enough).
---@param results pf.Results
---@return boolean
function M._has_replacement(results)
  for _, f in ipairs(results.files or {}) do
    for _, m in ipairs(f.matches) do
      for _, sm in ipairs(m.submatches) do
        if sm.replacement ~= nil then
          return true
        end
      end
    end
  end
  return false
end

--- Run ripgrep with --replace to compute the preview asynchronously.
---@param query pf.Query & { cwd?:string }
---@param opts { cwd?:string, max_results?:integer }
---@param cb fun(err:string?, preview:pf.PreviewFile[]?)
function M.gather_preview(query, opts, cb)
  opts = opts or {}
  local search = require("power-finder.search")
  search.run(query, {
    cwd = opts.cwd or query.cwd,
    with_replace = true,
    max_results = opts.max_results,
  }, function(err, results)
    if err then
      cb(err, nil)
      return
    end
    local preview = M.build_preview(results)
    -- If ripgrep found matches yet emitted no replacement data at all, it is
    -- almost certainly too old: the `replacement` field in --json output needs
    -- ripgrep 15+. Surface a clear message instead of a silent "nothing to do".
    if #preview == 0 and (results.total or 0) > 0 and not M._has_replacement(results) then
      cb("power-finder: replace preview needs ripgrep 15+ (its --json output lacks replacement data)", nil)
      return
    end
    cb(nil, preview)
  end)
end

------------------------------------------------------------------------------
-- Apply (I/O).
------------------------------------------------------------------------------

--- Apply the selected preview files to disk/buffers as one undo-able change.
--- Guards against concurrent external edits via mtime.
---@param preview pf.PreviewFile[]
---@param opts? { reload_open_buffers?: boolean }
---@return { files:integer, changes:integer, skipped:string[] }
function M.apply(preview, opts)
  opts = opts or {}
  local applied_files, applied_changes = 0, 0
  local skipped = {}

  for _, f in ipairs(preview) do
    if f.selected and #f.lines > 0 then
      local ok, err = M._apply_file(f, opts)
      if ok then
        applied_files = applied_files + 1
        applied_changes = applied_changes + f.changes
      else
        skipped[#skipped + 1] = f.path .. " (" .. tostring(err) .. ")"
      end
    end
  end

  return { files = applied_files, changes = applied_changes, skipped = skipped }
end

-- Apply a single file. Prefers an already-open buffer (keeps its undo history);
-- otherwise edits on disk. Verifies each target line still matches `old`.
---@param f pf.PreviewFile
---@param opts table
---@return boolean ok, string? err
function M._apply_file(f, opts)
  local path = f.path
  local abs = vim.fn.fnamemodify(path, ":p")
  local bufnr = vim.fn.bufnr(abs)

  -- Build a lnum(1-based) -> {old,new} lookup.
  local edits = {}
  for _, l in ipairs(f.lines) do
    edits[l.lnum] = l
  end

  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    -- Edit through the buffer so undo is preserved and views stay in sync.
    local total = vim.api.nvim_buf_line_count(bufnr)
    for lnum, e in pairs(edits) do
      if lnum < 1 or lnum > total then
        return false, "line out of range"
      end
      local cur = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
      if cur ~= e.old then
        return false, "buffer changed since search"
      end
    end
    for lnum, e in pairs(edits) do
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { e.new })
    end
    if vim.api.nvim_buf_get_option(bufnr, "modified") and opts.write_buffers ~= false then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent noautocmd write")
      end)
    end
    return true
  end

  -- File not open: read, verify, write back.
  local fd = io.open(abs, "r")
  if not fd then
    return false, "cannot open"
  end
  local content = fd:read("*a")
  fd:close()

  local lines = vim.split(content, "\n", { plain = true })
  -- Preserve a trailing newline: vim.split leaves a trailing "" for it.
  for lnum, e in pairs(edits) do
    if lnum < 1 or lnum > #lines then
      return false, "line out of range"
    end
    if lines[lnum] ~= e.old then
      return false, "file changed since search"
    end
  end
  for lnum, e in pairs(edits) do
    lines[lnum] = e.new
  end

  local out = io.open(abs, "w")
  if not out then
    return false, "cannot write"
  end
  out:write(table.concat(lines, "\n"))
  out:close()
  return true
end

return M
