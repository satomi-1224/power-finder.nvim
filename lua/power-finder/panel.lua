-- The integrated finder panel: a form window (editable search conditions)
-- stacked over a read-only results window. Toggles/scope/replace are driven by
-- buffer-local mappings. Everything a mapping does is a Panel method, so the
-- same surface is exercised by the headless smoke tests.
local config = require("power-finder.config")
local hl = require("power-finder.highlight")
local util = require("power-finder.util")
local scope_mod = require("power-finder.scope")
local search = require("power-finder.search")
local replace = require("power-finder.replace")

local M = {}
local NS = vim.api.nvim_create_namespace("power_finder")

local FIELDS = { "search", "replace", "include", "exclude" }
local LABELS = { search = "Search", replace = "Replace", include = "Include", exclude = "Exclude" }
local HEADER_ROWS = 2 -- status line + blank, before the file list

---@class pf.Panel
local Panel = {}
Panel.__index = Panel

M._current = nil

------------------------------------------------------------------------------
-- construction / geometry
------------------------------------------------------------------------------

function M.open(opts)
  if M._current and M._current:is_open() then
    M._current:focus()
    return M._current
  end
  local p = setmetatable({}, Panel)
  p:init(opts)
  p:open()
  M._current = p
  return p
end

function Panel:init(opts)
  self.opts = config.options
  opts = opts or {}
  local d = self.opts.defaults
  self.values = {
    search = opts.query or "",
    replace = "",
    include = d.include,
    exclude = d.exclude,
  }
  self.toggles = {
    regex = d.regex,
    case = self.opts.search.case,
    word = d.word,
  }
  self.scope = opts.scope or d.scope
  self.scope_paths = opts.scope_paths
  self.cwd = opts.cwd or vim.fn.getcwd()
  self.mode = "search"
  self.results = { files = {}, total = 0, truncated = false }
  self.line_index = {}
  self.preview = nil
  self.searcher = search.debounced({
    delay = self.opts.search.debounce_ms,
    min_query = self.opts.search.min_query,
    max_results = self.opts.search.max_results,
  })
end

local function geometry()
  local lay = config.options.layout
  local cols, rows = vim.o.columns, vim.o.lines
  local W = math.max(40, math.floor(cols * lay.width))
  local H = math.max(12, math.floor(rows * lay.height))
  local col0 = math.floor((cols - W) / 2)
  local row0 = math.max(0, math.floor((rows - H) / 2) - 1)
  local form_h = #FIELDS
  local res_h = math.max(3, H - form_h - 5)
  return {
    W = W,
    form = { row = row0, col = col0, width = W, height = form_h },
    res = { row = row0 + form_h + 3, col = col0, width = W, height = res_h },
  }
end

function Panel:open()
  local g = geometry()
  local border = self.opts.layout.border

  self.form_buf = vim.api.nvim_create_buf(false, true)
  self.res_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.form_buf].bufhidden = "wipe"
  vim.bo[self.res_buf].bufhidden = "wipe"
  vim.bo[self.form_buf].filetype = "PowerFinderForm"
  vim.bo[self.res_buf].filetype = "PowerFinderResults"
  vim.bo[self.res_buf].modifiable = false

  self.form_win = vim.api.nvim_open_win(self.form_buf, true, {
    relative = "editor",
    row = g.form.row,
    col = g.form.col,
    width = g.form.width,
    height = g.form.height,
    border = border,
    title = " Power Finder ",
    title_pos = "left",
    style = "minimal",
  })
  self.res_win = vim.api.nvim_open_win(self.res_buf, false, {
    relative = "editor",
    row = g.res.row,
    col = g.res.col,
    width = g.res.width,
    height = g.res.height,
    border = border,
    style = "minimal",
  })
  vim.wo[self.res_win].cursorline = true
  vim.wo[self.form_win].wrap = false
  vim.wo[self.res_win].wrap = false

  hl.setup()
  self:render_form()
  self:setup_mappings()
  self:setup_autocmds()
  self:render_results()

  -- Start in insert mode at the end of the search field.
  vim.api.nvim_set_current_win(self.form_win)
  vim.api.nvim_win_set_cursor(self.form_win, { 1, #self.values.search })
  if self.values.search ~= "" then
    self:schedule_search()
  end
end

function Panel:is_open()
  return self.form_win ~= nil and vim.api.nvim_win_is_valid(self.form_win)
end

function Panel:focus()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.form_win)
  end
end

function Panel:close()
  self.searcher:cancel()
  for _, w in ipairs({ self.form_win, self.res_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_close(w, true)
    end
  end
  self.form_win, self.res_win = nil, nil
  if M._current == self then
    M._current = nil
  end
end

------------------------------------------------------------------------------
-- form rendering + reading
------------------------------------------------------------------------------

function Panel:render_form()
  local lines = {}
  for i, f in ipairs(FIELDS) do
    lines[i] = self.values[f] or ""
  end
  vim.bo[self.form_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.form_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.form_buf, NS, 0, -1)
  for i, f in ipairs(FIELDS) do
    vim.api.nvim_buf_set_extmark(self.form_buf, NS, i - 1, 0, {
      virt_text = { { string.format("%-9s", LABELS[f]), "PowerFinderLabel" } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
  end
end

-- Keep the form at exactly #FIELDS lines even if the user hits <CR>.
function Panel:normalize_form()
  local n = vim.api.nvim_buf_line_count(self.form_buf)
  if n ~= #FIELDS then
    local lines = vim.api.nvim_buf_get_lines(self.form_buf, 0, -1, false)
    -- collapse any accidental newlines: keep first #FIELDS non-structural lines
    while #lines > #FIELDS do
      table.remove(lines)
    end
    while #lines < #FIELDS do
      lines[#lines + 1] = ""
    end
    vim.api.nvim_buf_set_lines(self.form_buf, 0, -1, false, lines)
  end
end

function Panel:read_form()
  self:normalize_form()
  local lines = vim.api.nvim_buf_get_lines(self.form_buf, 0, #FIELDS, false)
  for i, f in ipairs(FIELDS) do
    self.values[f] = lines[i] or ""
  end
end

------------------------------------------------------------------------------
-- query building + search
------------------------------------------------------------------------------

function Panel:gather_query()
  self:read_form()
  local s = self.opts.search
  return {
    query = self.values.search,
    replace = self.values.replace,
    include_globs = util.split_csv(self.values.include),
    exclude_globs = util.split_csv(self.values.exclude),
    paths = scope_mod.resolve(self.scope, { cwd = self.cwd, scope_paths = self.scope_paths }),
    regex = self.toggles.regex,
    case = self.toggles.case,
    word = self.toggles.word,
    hidden = s.hidden,
    no_ignore = s.no_ignore,
    max_columns = s.max_columns,
  }
end

function Panel:schedule_search()
  if self.mode ~= "search" then
    return
  end
  local q = self:gather_query()
  self.searcher:request(q, function(err, results)
    if not self:is_open() then
      return
    end
    if err then
      self.results = { files = {}, total = 0, truncated = false, error = err }
    else
      self.results = results
    end
    self:render_results()
  end)
end

------------------------------------------------------------------------------
-- results rendering
------------------------------------------------------------------------------

function Panel:status_text()
  local t = self.toggles
  local flags = string.format("[regex:%s case:%s word:%s]", t.regex and "on" or "off", t.case, t.word and "on" or "off")
  local scope = "scope:" .. self.scope
  if self.results.error then
    return "⚠ " .. self.results.error .. "   " .. flags
  end
  local n = self.results.total or 0
  local files = #(self.results.files or {})
  local trunc = self.results.truncated and " (truncated)" or ""
  return string.format("%d matches · %d files%s   %s   %s", n, files, trunc, flags, scope)
end

function Panel:render_results()
  local lines = { self:status_text(), "" }
  local index = {} -- res line (1-based) -> item
  index[1] = { kind = "status" }
  index[2] = { kind = "blank" }

  local marks = {} -- {row0, col0, col1, hl}
  for _, f in ipairs(self.results.files or {}) do
    local disc = f.collapsed and "▶" or "▼"
    local header = string.format("%s %s  (%d)", disc, f.path, #f.matches)
    lines[#lines + 1] = header
    index[#lines] = { kind = "file", file = f }
    if not f.collapsed then
      for _, m in ipairs(f.matches) do
        local ln = string.format("%5d  %s", m.lnum, m.text)
        lines[#lines + 1] = ln
        index[#lines] = { kind = "match", file = f, match = m }
        -- highlight each submatch within the printed line
        local prefix = 7 -- "%5d" + two spaces
        for _, sm in ipairs(m.submatches) do
          marks[#marks + 1] = {
            row = #lines - 1,
            col = prefix + sm.start,
            col_end = prefix + sm.finish,
          }
        end
      end
    end
  end

  self.line_index = index
  vim.bo[self.res_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.res_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.res_buf, NS, 0, -1)
  -- status line highlight
  vim.api.nvim_buf_set_extmark(self.res_buf, NS, 0, 0, {
    end_row = 1,
    hl_group = "PowerFinderStatus",
    hl_eol = true,
  })
  for i = 3, #lines do
    if index[i] and index[i].kind == "file" then
      vim.api.nvim_buf_set_extmark(self.res_buf, NS, i - 1, 0, {
        end_row = i,
        hl_group = "PowerFinderFile",
        hl_eol = false,
        end_col = 0,
      })
    end
  end
  for _, mk in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, self.res_buf, NS, mk.row, mk.col, {
      end_row = mk.row,
      end_col = mk.col_end,
      hl_group = "PowerFinderMatch",
    })
  end
  vim.bo[self.res_buf].modifiable = false
end

------------------------------------------------------------------------------
-- navigation / actions
------------------------------------------------------------------------------

function Panel:item_at_cursor()
  if not (self.res_win and vim.api.nvim_win_is_valid(self.res_win)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(self.res_win)[1]
  return self.line_index[row]
end

function Panel:open_selected(how)
  local item = self:item_at_cursor()
  if not item or (item.kind ~= "match" and item.kind ~= "file") then
    return
  end
  local path = item.file.path
  local lnum = item.kind == "match" and item.match.lnum or 1
  local col = 0
  if item.kind == "match" and item.match.submatches[1] then
    col = item.match.submatches[1].start
  end
  -- jump to a normal window (leave the finder open above it)
  local target = self:pick_target_window()
  vim.api.nvim_set_current_win(target)
  local cmd = ({ edit = "edit", split = "split", vsplit = "vsplit" })[how] or "edit"
  vim.cmd(cmd .. " " .. vim.fn.fnameescape(vim.fn.fnamemodify(path, ":p")))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col })
  vim.cmd("normal! zz")
end

function Panel:pick_target_window()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= self.form_win and w ~= self.res_win and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  -- no normal window; make one
  vim.cmd("botright new")
  return vim.api.nvim_get_current_win()
end

function Panel:toggle_fold()
  local item = self:item_at_cursor()
  if item and item.file then
    item.file.collapsed = not item.file.collapsed
    self:render_results()
  end
end

function Panel:toggle(name)
  if name == "regex" then
    self.toggles.regex = not self.toggles.regex
  elseif name == "word" then
    self.toggles.word = not self.toggles.word
  elseif name == "case" then
    local order = { smart = "sensitive", sensitive = "ignore", ignore = "smart" }
    self.toggles.case = order[self.toggles.case] or "smart"
  end
  self:schedule_search()
end

function Panel:set_scope(scope, paths)
  self.scope = scope
  self.scope_paths = paths
  self:schedule_search()
end

function Panel:pick_scope()
  local ok_fzf, fzf = pcall(require, "power-finder.fzf")
  if self.opts.fzf.use_for_scope_picker and ok_fzf and fzf.available() then
    fzf.pick_scope(self)
    return
  end
  vim.ui.select({ "project", "cwd", "buffers", "path" }, { prompt = "Search scope" }, function(choice)
    if not choice then
      return
    end
    if choice == "path" then
      vim.ui.input({ prompt = "Path: ", default = self.cwd, completion = "dir" }, function(p)
        if p and p ~= "" then
          self:set_scope("path", { p })
        end
      end)
    else
      self:set_scope(choice)
    end
  end)
end

function Panel:to_quickfix()
  local items = {}
  for _, f in ipairs(self.results.files or {}) do
    local abs = vim.fn.fnamemodify(f.path, ":p")
    for _, m in ipairs(f.matches) do
      items[#items + 1] = {
        filename = abs,
        lnum = m.lnum,
        col = (m.submatches[1] and m.submatches[1].start or 0) + 1,
        text = m.text,
      }
    end
  end
  vim.fn.setqflist({}, " ", { title = "PowerFinder: " .. self.values.search, items = items })
  self:close()
  vim.cmd("copen")
end

------------------------------------------------------------------------------
-- replace preview mode
------------------------------------------------------------------------------

function Panel:enter_preview()
  self:read_form()
  if self.values.replace == "" then
    vim.notify("power-finder: Replace field is empty", vim.log.levels.WARN)
    return
  end
  self.searcher:cancel()
  local q = self:gather_query()
  q.cwd = self.cwd
  replace.gather_preview(q, { cwd = self.cwd, max_results = self.opts.search.max_results }, function(err, preview)
    if not self:is_open() then
      return
    end
    if err then
      vim.notify("power-finder: " .. err, vim.log.levels.ERROR)
      return
    end
    if #preview == 0 then
      vim.notify("power-finder: nothing to replace", vim.log.levels.INFO)
      return
    end
    self.mode = "preview"
    self.preview = preview
    self:render_preview()
    vim.api.nvim_set_current_win(self.res_win)
    pcall(vim.api.nvim_win_set_cursor, self.res_win, { HEADER_ROWS + 1, 0 })
  end)
end

function Panel:render_preview()
  local from = self.values.search
  local to = self.values.replace
  local s = replace.summarize(self.preview)
  local head =
    string.format("Replace: %s → %s    apply %d/%d files · %d changes", from, to, s.files, s.total_files, s.changes)
  local lines = { head, "" }
  local index = { [1] = { kind = "phead" }, [2] = { kind = "blank" } }
  local marks = {}

  for _, f in ipairs(self.preview) do
    local box = f.selected and "[x]" or "[ ]"
    lines[#lines + 1] = string.format("%s %s  (%d)", box, f.path, f.changes)
    index[#lines] = { kind = "pfile", file = f }
    local hlname = f.selected and "PowerFinderSelected" or "PowerFinderDeselected"
    marks[#marks + 1] = { row = #lines - 1, hl = hlname, whole = true }
    for _, l in ipairs(f.lines) do
      lines[#lines + 1] = string.format("%5d -%s", l.lnum, l.old)
      index[#lines] = { kind = "pdel" }
      marks[#marks + 1] = { row = #lines - 1, hl = "PowerFinderDiffDelete", whole = true }
      lines[#lines + 1] = string.format("      +%s", l.new)
      index[#lines] = { kind = "padd" }
      marks[#marks + 1] = { row = #lines - 1, hl = "PowerFinderDiffAdd", whole = true }
    end
  end

  self.line_index = index
  vim.bo[self.res_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.res_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.res_buf, NS, 0, -1)
  for _, mk in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, self.res_buf, NS, mk.row, 0, {
      end_row = mk.row + 1,
      end_col = 0,
      hl_group = mk.hl,
      hl_eol = true,
    })
  end
  vim.bo[self.res_buf].modifiable = false
end

function Panel:toggle_preview_file()
  local item = self:item_at_cursor()
  if item and item.kind == "pfile" then
    item.file.selected = not item.file.selected
    self:render_preview()
  end
end

function Panel:select_all(v)
  for _, f in ipairs(self.preview or {}) do
    f.selected = v
  end
  self:render_preview()
end

function Panel:apply()
  if self.mode ~= "preview" or not self.preview then
    return
  end
  local res = replace.apply(self.preview, { write_buffers = self.opts.replace.write_buffers })
  local msg = string.format("Replaced %d occurrences in %d files", res.changes, res.files)
  if #res.skipped > 0 then
    msg = msg .. string.format(" (%d skipped)", #res.skipped)
  end
  vim.notify("power-finder: " .. msg, vim.log.levels.INFO)
  self:exit_preview()
end

function Panel:exit_preview()
  self.mode = "search"
  self.preview = nil
  self:render_results()
  self:focus()
end

------------------------------------------------------------------------------
-- mappings / autocmds
------------------------------------------------------------------------------

function Panel:map(bufs, modes, lhs, fn)
  if not lhs then
    return
  end
  for _, b in ipairs(bufs) do
    vim.keymap.set(modes, lhs, fn, { buffer = b, nowait = true, silent = true })
  end
end

function Panel:setup_mappings()
  local m = self.opts.mappings
  local both = { self.form_buf, self.res_buf }
  local self_ = self

  self:map(both, { "n" }, m.close, function()
    if self_.mode == "preview" then
      self_:exit_preview()
    else
      self_:close()
    end
  end)
  self:map(both, { "n", "i" }, m.toggle_regex, function()
    self_:toggle("regex")
  end)
  self:map(both, { "n", "i" }, m.toggle_case, function()
    self_:toggle("case")
  end)
  self:map(both, { "n", "i" }, m.toggle_word, function()
    self_:toggle("word")
  end)
  self:map(both, { "n", "i" }, m.scope_picker, function()
    self_:pick_scope()
  end)
  self:map(both, { "n", "i" }, m.replace_preview, function()
    self_:enter_preview()
  end)

  -- results/preview-only
  self:map({ self.res_buf }, { "n" }, m.open, function()
    if self_.mode == "preview" then
      self_:apply()
    else
      self_:open_selected("edit")
    end
  end)
  self:map({ self.res_buf }, { "n" }, m.open_split, function()
    self_:open_selected("split")
  end)
  self:map({ self.res_buf }, { "n" }, m.open_vsplit, function()
    self_:open_selected("vsplit")
  end)
  self:map({ self.res_buf }, { "n" }, m.fold, function()
    if self_.mode == "preview" then
      self_:toggle_preview_file()
    else
      self_:toggle_fold()
    end
  end)
  self:map({ self.res_buf }, { "n" }, "<Space>", function()
    if self_.mode == "preview" then
      self_:toggle_preview_file()
    end
  end)
  self:map({ self.res_buf }, { "n" }, m.to_quickfix, function()
    self_:to_quickfix()
  end)

  -- window hop: from form, <C-j> to results; from results, <C-k> to form
  self:map({ self.form_buf }, { "n", "i" }, "<C-j>", function()
    if self_.res_win and vim.api.nvim_win_is_valid(self_.res_win) then
      vim.cmd("stopinsert")
      vim.api.nvim_set_current_win(self_.res_win)
    end
  end)
  self:map({ self.res_buf }, { "n" }, "<C-k>", function()
    self_:focus()
  end)
end

function Panel:setup_autocmds()
  local grp = vim.api.nvim_create_augroup("PowerFinder_" .. self.form_buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = grp,
    buffer = self.form_buf,
    callback = function()
      self:schedule_search()
    end,
  })
  -- close everything if either window is left/closed
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(ev)
      local w = tonumber(ev.match)
      if w == self.form_win or w == self.res_win then
        vim.schedule(function()
          self:close()
        end)
      end
    end,
  })
end

------------------------------------------------------------------------------
-- test hooks (used by the headless smoke test; harmless in normal use)
------------------------------------------------------------------------------

--- Set form values programmatically (as if typed).
function Panel:_set_values(vals)
  for k, v in pairs(vals) do
    self.values[k] = v
  end
  self:render_form()
end

--- Run a search synchronously (bypasses debounce) and invoke cb after render.
function Panel:_search_now(cb)
  local q = self:gather_query()
  search.run(q, { max_results = self.opts.search.max_results }, function(err, results)
    self.results = err and { files = {}, total = 0, truncated = false, error = err } or results
    self:render_results()
    if cb then
      cb(err, results)
    end
  end)
end

function Panel:_results_lines()
  return vim.api.nvim_buf_get_lines(self.res_buf, 0, -1, false)
end

return M
