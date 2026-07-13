-- The integrated finder panel: a form window (editable search conditions)
-- stacked over a read-only results window, styled after IntelliJ / Zed's
-- "Find in Files". Toggles are shown as chips on the search row, keybindings
-- live in the results window footer, and the whole panel paints an opaque
-- background so it never washes out into the colorscheme.
--
-- Everything a mapping does is a Panel method, so the same surface is exercised
-- by the headless smoke tests.
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
local LABEL_W = 9 -- inline label column width (chars), incl. trailing padding
local HEADER_ROWS = 2 -- status line + blank, before the file list

local SCOPES = { "project", "cwd", "buffers", "path" }
local SCOPE_LABEL = { project = "Project", cwd = "Cwd", buffers = "Buffers", path = "Path" }

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
  -- Reopening reuses the conditions from the previous panel for the rest of the
  -- nvim session (M._last_state), unless the caller overrides a field (e.g.
  -- open_cword/open_visual pass a fresh query). Cleared when nvim exits.
  local last = M._last_state or {}
  local lv = last.values or {}
  self.values = {
    search = opts.query or lv.search or "",
    replace = lv.replace or "",
    include = lv.include or d.include,
    exclude = lv.exclude or d.exclude,
  }
  self.toggles = last.toggles and vim.deepcopy(last.toggles)
    or {
      regex = d.regex,
      case = self.opts.search.case,
      word = d.word,
    }
  self.scope = opts.scope or last.scope or d.scope
  self.scope_paths = opts.scope_paths or last.scope_paths
  self.cwd = opts.cwd or vim.fn.getcwd()
  self.mode = "search"
  self.results = { files = {}, total = 0, truncated = false }
  self.line_index = {}
  self.preview = nil
  -- paths the user has unchecked in replace mode; persists across live rebuilds
  self.replace_deselected = {}
  self.searcher = search.debounced({
    delay = self.opts.search.debounce_ms,
    min_query = self.opts.search.min_query,
    max_results = self.opts.search.max_results,
  })
end

local function geometry()
  local lay = config.options.layout
  local cols, rows = vim.o.columns, vim.o.lines
  local W = math.max(48, math.floor(cols * lay.width))
  local H = math.max(14, math.floor(rows * lay.height))
  local col0 = math.floor((cols - W) / 2)
  local row0 = math.max(0, math.floor((rows - H) / 2) - 1)
  local form_h = #FIELDS
  -- account for both borders (2 each) + the gap between windows + footer.
  local res_h = math.max(4, H - form_h - 6)
  return {
    W = W,
    form = { row = row0, col = col0, width = W, height = form_h },
    res = { row = row0 + form_h + 3, col = col0, width = W, height = res_h },
  }
end

function Panel:open()
  local g = geometry()
  local border = self.opts.layout.border
  self.res_width = g.res.width

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
    title = self:form_title(),
    title_pos = "left",
    style = "minimal",
    zindex = 60,
  })
  self.res_win = vim.api.nvim_open_win(self.res_buf, false, {
    relative = "editor",
    row = g.res.row,
    col = g.res.col,
    width = g.res.width,
    height = g.res.height,
    border = border,
    style = "minimal",
    footer = self:footer_chunks(),
    footer_pos = "center",
    zindex = 60,
  })

  hl.setup()
  self:style_window(self.form_win, false)
  self:style_window(self.res_win, true)

  self:render_form()
  self:setup_mappings()
  self:setup_autocmds()
  self:render_results()

  -- Start in insert mode at the end of the search field.
  vim.api.nvim_set_current_win(self.form_win)
  vim.api.nvim_win_set_cursor(self.form_win, { 1, #self.values.search })
  vim.cmd("startinsert!")
  if self.values.search ~= "" then
    self:schedule_search()
  end
end

-- Force an opaque, panel-specific look regardless of the colorscheme: kill any
-- inherited transparency (winblend) and remap Normal/border/cursorline.
function Panel:style_window(win, is_results)
  vim.wo[win].winblend = 0
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = is_results
  local wh =
    "Normal:PowerFinderNormal,FloatBorder:PowerFinderBorder,FloatTitle:PowerFinderTitle,FloatFooter:PowerFinderFooter"
  if is_results then
    wh = wh .. ",CursorLine:PowerFinderCursorLine"
  end
  vim.wo[win].winhighlight = wh
end

function Panel:form_title()
  return { { "  Power Finder ", "PowerFinderTitle" } }
end

function Panel:is_open()
  return self.form_win ~= nil and vim.api.nvim_win_is_valid(self.form_win)
end

function Panel:focus()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.form_win)
  end
end

-- Snapshot the current conditions into the module so the next open() restores
-- them (persists until nvim exits).
function Panel:save_state()
  if self.form_buf and vim.api.nvim_buf_is_valid(self.form_buf) then
    pcall(function()
      self:read_form()
    end)
  end
  M._last_state = {
    values = vim.deepcopy(self.values),
    toggles = vim.deepcopy(self.toggles),
    scope = self.scope,
    scope_paths = self.scope_paths and vim.deepcopy(self.scope_paths) or nil,
  }
end

function Panel:close()
  self.searcher:cancel()
  self.closing = true
  self:save_state()
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
  self:apply_form_marks()
end

local PLACEHOLDER = {
  search = "type to search…",
  -- replace is handled specially (mode-dependent) in apply_form_marks
  include = "e.g. *.ts, src/**  (blank = all files)",
  exclude = "e.g. **/node_modules/**",
}

-- The virtual chrome of the form: the left-hand field labels, per-field
-- placeholders shown while a field is empty, and the toggle chips on the
-- search row. Reads live buffer text so it stays correct on every keystroke.
function Panel:apply_form_marks()
  vim.api.nvim_buf_clear_namespace(self.form_buf, NS, 0, -1)
  local cur = vim.api.nvim_buf_get_lines(self.form_buf, 0, #FIELDS, false)
  for i, f in ipairs(FIELDS) do
    local empty = (cur[i] or "") == ""
    -- which field is the "live" one for the current mode
    local active = (f == "search" and self.mode == "search") or (f == "replace" and self.mode == "preview")
    local hlg = (active and not empty) and "PowerFinderPrompt" or "PowerFinderLabel"
    vim.api.nvim_buf_set_extmark(self.form_buf, NS, i - 1, 0, {
      virt_text = { { " " .. string.format("%-" .. (LABEL_W - 1) .. "s", LABELS[f]), hlg } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
    local ph = PLACEHOLDER[f]
    if f == "replace" then
      -- Replace is only editable in replace mode; hint how to get there.
      ph = self.mode == "preview" and "type a replacement… (live)" or "press C-d to replace"
    end
    if empty and ph then
      vim.api.nvim_buf_set_extmark(self.form_buf, NS, i - 1, 0, {
        virt_text = { { ph, "PowerFinderGhost" } },
        virt_text_pos = "eol",
      })
    end
  end

  -- toggle chips, right-aligned on the search row
  local t = self.toggles
  local case_label, case_hl
  if t.case == "sensitive" then
    case_label, case_hl = "Aa", "PowerFinderToggleOn"
  elseif t.case == "smart" then
    case_label, case_hl = "Aa", "PowerFinderToggleCase"
  else
    case_label, case_hl = "aa", "PowerFinderToggleOff"
  end
  local function chip(label, hlg)
    return { " " .. label .. " ", hlg }
  end
  local gap = { " ", "PowerFinderNormal" }
  vim.api.nvim_buf_set_extmark(self.form_buf, NS, 0, 0, {
    virt_text = {
      chip(".*", t.regex and "PowerFinderToggleOn" or "PowerFinderToggleOff"),
      gap,
      chip(case_label, case_hl),
      gap,
      chip("W", t.word and "PowerFinderToggleOn" or "PowerFinderToggleOff"),
      { " ", "PowerFinderNormal" },
    },
    virt_text_pos = "right_align",
  })
end

-- Keep the form at exactly #FIELDS lines even if a structural edit slips
-- through the guards. Returns true if it had to repair the buffer.
function Panel:normalize_form()
  local n = vim.api.nvim_buf_line_count(self.form_buf)
  if n == #FIELDS then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(self.form_buf, 0, -1, false)
  while #lines > #FIELDS do
    table.remove(lines)
  end
  while #lines < #FIELDS do
    lines[#lines + 1] = ""
  end
  vim.bo[self.form_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.form_buf, 0, -1, false, lines)
  return true
end

function Panel:read_form()
  self:normalize_form()
  local lines = vim.api.nvim_buf_get_lines(self.form_buf, 0, #FIELDS, false)
  for i, f in ipairs(FIELDS) do
    self.values[f] = lines[i] or ""
  end
end

-- Jump the cursor to another form field (Tab / Shift-Tab), wrapping around.
function Panel:move_field(delta)
  if not (self.form_win and vim.api.nvim_win_is_valid(self.form_win)) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(self.form_win)[1]
  local nr = ((row - 1 + delta) % #FIELDS) + 1
  local line = vim.api.nvim_buf_get_lines(self.form_buf, nr - 1, nr, false)[1] or ""
  vim.api.nvim_win_set_cursor(self.form_win, { nr, #line })
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
    -- Guard against a late result landing after we've entered replace preview
    -- (it would otherwise clobber the diff view).
    if not self:is_open() or self.mode ~= "search" then
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

-- Live replace: re-run ripgrep with --replace and rebuild the diff on every
-- change while in replace mode. When the Replace field is empty we just show
-- the matches so the user sees what will be affected.
function Panel:schedule_replace()
  if self.mode ~= "preview" then
    return
  end
  local q = self:gather_query()
  q.cwd = self.cwd
  local has_replace = self.values.replace ~= ""
  q.with_replace = has_replace
  self.searcher:request(q, function(err, results)
    if not self:is_open() or self.mode ~= "preview" then
      return
    end
    if err then
      self.results = { files = {}, total = 0, truncated = false, error = err }
      self.preview = nil
    elseif not has_replace then
      self.results = results
      self.preview = nil
    elseif #(results.files or {}) > 0 and (results.total or 0) > 0 and not replace._has_replacement(results) then
      -- ripgrep too old to report replacement data
      self.results = results
      self.results.error = "replace preview needs ripgrep 15+ (its --json output lacks replacement data)"
      self.preview = nil
    else
      local preview = replace.build_preview(results)
      for _, f in ipairs(preview) do
        f.selected = not self.replace_deselected[f.path]
      end
      self.preview = preview
    end
    self:render_replace()
  end)
end

------------------------------------------------------------------------------
-- results rendering
------------------------------------------------------------------------------

-- A file's path for display: relative to the search root when possible, then
-- home-relative, then shortened to keep the tail (filename) visible. The real
-- path stays on the item for opening.
function Panel:display_path(path)
  local base = vim.fn.fnamemodify(self.cwd, ":p")
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  local full = vim.fn.fnamemodify(path, ":p")
  local rel
  if full:sub(1, #base) == base then
    rel = full:sub(#base + 1)
  else
    rel = vim.fn.fnamemodify(path, ":~")
  end
  if rel == "" then
    rel = path
  end
  return util.shorten(rel, 72)
end

-- Build a status line as text + a list of {s, e, hl} byte-range overlays.
function Panel:status_segments()
  local parts, marks = {}, {}
  local col = 0
  local function add(text, hlg)
    parts[#parts + 1] = text
    if hlg then
      marks[#marks + 1] = { s = col, e = col + #text, hl = hlg }
    end
    col = col + #text
  end

  if self.results.error then
    add(" ⚠ ", "PowerFinderError")
    add(self.results.error, "PowerFinderError")
    return table.concat(parts), marks
  end

  local n = self.results.total or 0
  local files = #(self.results.files or {})
  add(" ")
  add(tostring(n), "PowerFinderStatusNum")
  add(string.format(" match%s · ", n == 1 and "" or "es"))
  add(tostring(files), "PowerFinderStatusNum")
  add(" file" .. (files == 1 and "" or "s"))
  if self.results.truncated then
    add("  (truncated)", "PowerFinderStatusInfo")
  end
  add("    scope: ")
  add(SCOPE_LABEL[self.scope] or self.scope, "PowerFinderStatusScope")
  return table.concat(parts), marks
end

function Panel:render_results()
  local status, status_marks = self:status_segments()
  local lines = { status, "" }
  local index = {} -- res line (1-based) -> item
  index[1] = { kind = "status" }
  index[2] = { kind = "blank" }

  local marks = {} -- {row0, col0, col1, hl}
  local files = self.results.files or {}

  if #files == 0 then
    local hint
    if not self.results.error then
      hint = (self.values.search == "" and "   Type in the Search field to begin…" or "   No matches.")
    end
    if hint then
      lines[#lines + 1] = ""
      lines[#lines + 1] = hint
      index[#lines] = { kind = "hint" }
      marks[#marks + 1] = { row = #lines - 1, whole = true, hl = "PowerFinderGhost" }
    end
  end

  for _, f in ipairs(files) do
    local disc = f.collapsed and "▸" or "▾"
    local header = string.format(" %s %s  (%d)", disc, self:display_path(f.path), #f.matches)
    lines[#lines + 1] = header
    index[#lines] = { kind = "file", file = f }
    local row = #lines - 1
    marks[#marks + 1] = { row = row, whole = true, hl = "PowerFinderFile" }
    marks[#marks + 1] = { row = row, col = 1, col_end = 4, hl = "PowerFinderDisc" }
    -- dim the "(n)" count
    local cs = header:find("%(%d+%)$")
    if cs then
      marks[#marks + 1] = { row = row, col = cs - 1, col_end = #header, hl = "PowerFinderCount" }
    end
    if not f.collapsed then
      for _, m in ipairs(f.matches) do
        local ln = string.format("%6d  %s", m.lnum, m.text)
        lines[#lines + 1] = ln
        index[#lines] = { kind = "match", file = f, match = m }
        local mrow = #lines - 1
        local prefix = 8 -- "%6d" + two spaces
        marks[#marks + 1] = { row = mrow, col = 0, col_end = 6, hl = "PowerFinderLineNr" }
        for _, sm in ipairs(m.submatches) do
          marks[#marks + 1] = {
            row = mrow,
            col = prefix + sm.start,
            col_end = prefix + sm.finish,
            hl = "PowerFinderMatch",
          }
        end
      end
    end
  end

  self.line_index = index
  vim.bo[self.res_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.res_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.res_buf, NS, 0, -1)

  -- status line background + segment overlays
  vim.api.nvim_buf_set_extmark(self.res_buf, NS, 0, 0, {
    end_row = 1,
    hl_group = "PowerFinderStatus",
    hl_eol = true,
  })
  for _, mk in ipairs(status_marks) do
    pcall(vim.api.nvim_buf_set_extmark, self.res_buf, NS, 0, mk.s, {
      end_col = mk.e,
      hl_group = mk.hl,
    })
  end

  self:apply_marks(marks)
  vim.bo[self.res_buf].modifiable = false
end

-- Apply a list of highlight marks. `whole` spans the entire line (hl_eol),
-- otherwise [col, col_end) on `row`.
function Panel:apply_marks(marks)
  for _, mk in ipairs(marks) do
    if mk.whole then
      pcall(vim.api.nvim_buf_set_extmark, self.res_buf, NS, mk.row, 0, {
        end_row = mk.row + 1,
        end_col = 0,
        hl_group = mk.hl,
        hl_eol = true,
      })
    else
      pcall(vim.api.nvim_buf_set_extmark, self.res_buf, NS, mk.row, mk.col, {
        end_row = mk.row,
        end_col = mk.col_end,
        hl_group = mk.hl,
      })
    end
  end
end

------------------------------------------------------------------------------
-- footer / keybar
------------------------------------------------------------------------------

local function disp(key)
  if not key then
    return "?"
  end
  return (key:gsub("[<>]", ""))
end

-- Assemble the keybar, degrading gracefully so it never overflows (and gets
-- truncated with an ugly "<") on a narrow window: full labels first, then
-- keys only, then fewer keys.
function Panel:footer_chunks()
  local m = self.opts.mappings
  local items
  if self.mode == "preview" then
    items = {
      { disp(m.open), "apply" },
      { "Space", "toggle" },
      { "C-a", "all" },
      { "C-x", "none" },
      { "Esc", "back" },
    }
  else
    items = {
      { "Tab", "pane" },
      { "Spc", "fold" },
      { disp(m.toggle_regex), "regex" },
      { disp(m.toggle_case), "case" },
      { disp(m.toggle_word), "word" },
      { disp(m.scope_picker), "scope" },
      { disp(m.replace_preview), "replace" },
      { "Esc", "close" },
    }
  end

  local avail = (self.res_width or 80) - 4 -- corner chars + a dash each side

  local function build(list, with_desc)
    local chunks, width = {}, 0
    local function push(text, hlg)
      chunks[#chunks + 1] = { text, hlg }
      width = width + vim.fn.strdisplaywidth(text)
    end
    push(" ", "PowerFinderFooter")
    for i, kv in ipairs(list) do
      if i > 1 then
        push(" · ", "PowerFinderFooter")
      end
      push(kv[1], "PowerFinderKey")
      if with_desc then
        push(" " .. kv[2], "PowerFinderKeyDesc")
      end
    end
    push(" ", "PowerFinderFooter")
    return chunks, width
  end

  local chunks, width = build(items, true)
  if width <= avail then
    return chunks
  end
  chunks, width = build(items, false) -- keys only
  local list = vim.deepcopy(items)
  while width > avail and #list > 3 do
    table.remove(list) -- drop from the end (least critical)
    chunks, width = build(list, false)
  end
  return chunks
end

function Panel:update_footer()
  if not (self.res_win and vim.api.nvim_win_is_valid(self.res_win)) then
    return
  end
  local cfg = vim.api.nvim_win_get_config(self.res_win)
  self.res_width = cfg.width or self.res_width
  cfg.footer = self:footer_chunks()
  cfg.footer_pos = "center"
  pcall(vim.api.nvim_win_set_config, self.res_win, cfg)
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
  -- Close the finder first (saving state), then jump. Jumping first would make
  -- pick_target_window race with the closing floats.
  self:close()
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
  self:apply_form_marks()
  self:schedule_search()
end

function Panel:set_scope(scope, paths)
  self.scope = scope
  self.scope_paths = paths
  self:schedule_search()
  if self.mode == "search" then
    self:render_results()
  end
end

function Panel:pick_scope()
  local ok_fzf, fzf = pcall(require, "power-finder.fzf")
  if self.opts.fzf.use_for_scope_picker and ok_fzf and fzf.available() then
    fzf.pick_scope(self)
    return
  end
  vim.ui.select(SCOPES, {
    prompt = "Search scope",
    format_item = function(s)
      return SCOPE_LABEL[s] or s
    end,
  }, function(choice)
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

-- Enter replace mode: the Replace field becomes editable and focused, and the
-- diff updates live as the replacement (or search) changes. C-d again re-focuses
-- the Replace field.
function Panel:enter_preview()
  self:read_form()
  self.mode = "preview"
  self.preview = nil
  self.replace_deselected = {}
  self:apply_form_marks()
  self:update_footer()
  self:focus()
  pcall(vim.api.nvim_win_set_cursor, self.form_win, { 2, #(self.values.replace or "") })
  vim.cmd("startinsert!")
  self:schedule_replace()
end

function Panel:render_replace()
  -- Before a replacement is typed (or on error) show the plain matches so the
  -- user can see what will be affected.
  if not self.preview then
    self:render_results()
    return
  end
  local from = self.values.search
  local to = self.values.replace
  local s = replace.summarize(self.preview)
  local head =
    string.format("Replace: %s → %s    apply %d/%d files · %d changes", from, to, s.files, s.total_files, s.changes)
  local lines = { head, "" }
  local index = { [1] = { kind = "phead" }, [2] = { kind = "blank" } }
  local marks = {}

  -- color the from/to terms in the header
  marks[#marks + 1] = { row = 0, col = 9, col_end = 9 + #from, hl = "PowerFinderReplaceFrom" }
  local to_at = 9 + #from + #" → "
  marks[#marks + 1] = { row = 0, col = to_at, col_end = to_at + #to, hl = "PowerFinderReplaceTo" }

  for _, f in ipairs(self.preview) do
    local box = f.selected and "✓" or "○"
    lines[#lines + 1] = string.format(" %s %s  (%d)", box, self:display_path(f.path), f.changes)
    index[#lines] = { kind = "pfile", file = f }
    local row = #lines - 1
    marks[#marks + 1] =
      { row = row, whole = true, hl = f.selected and "PowerFinderSelected" or "PowerFinderDeselected" }
    marks[#marks + 1] =
      { row = row, col = 1, col_end = 4, hl = f.selected and "PowerFinderCheckbox" or "PowerFinderCheckboxOff" }
    if not f.selected then
      lines[#lines] = lines[#lines] .. "  — excluded"
    end
    -- Always show the hunks; dim them when the file is deselected (mockup UX).
    for _, l in ipairs(f.lines) do
      lines[#lines + 1] = string.format("%6d -%s", l.lnum, l.old)
      index[#lines] = { kind = "pdel" }
      local drow = #lines - 1
      if f.selected then
        marks[#marks + 1] = { row = drow, whole = true, hl = "PowerFinderDiffDelete" }
        marks[#marks + 1] = { row = drow, col = 6, col_end = 8, hl = "PowerFinderDiffDelSign" }
      else
        marks[#marks + 1] = { row = drow, whole = true, hl = "PowerFinderDeselected" }
      end
      lines[#lines + 1] = string.format("       +%s", l.new)
      index[#lines] = { kind = "padd" }
      local arow = #lines - 1
      if f.selected then
        marks[#marks + 1] = { row = arow, whole = true, hl = "PowerFinderDiffAdd" }
        marks[#marks + 1] = { row = arow, col = 6, col_end = 8, hl = "PowerFinderDiffAddSign" }
      else
        marks[#marks + 1] = { row = arow, whole = true, hl = "PowerFinderDeselected" }
      end
    end
  end

  self.line_index = index
  vim.bo[self.res_buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.res_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(self.res_buf, NS, 0, -1)
  self:apply_marks(marks)
  vim.bo[self.res_buf].modifiable = false
end

function Panel:toggle_preview_file()
  local item = self:item_at_cursor()
  if item and item.kind == "pfile" then
    item.file.selected = not item.file.selected
    self.replace_deselected[item.file.path] = (not item.file.selected) or nil
    self:render_replace()
  end
end

function Panel:select_all(v)
  for _, f in ipairs(self.preview or {}) do
    f.selected = v
    self.replace_deselected[f.path] = (not v) or nil
  end
  self:render_replace()
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
  self.replace_deselected = {}
  self:apply_form_marks()
  self:update_footer()
  self:focus()
  pcall(vim.api.nvim_win_set_cursor, self.form_win, { 1, #(self.values.search or "") })
  vim.cmd("startinsert!")
  self:schedule_search()
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

  local function close_or_back()
    if self_.mode == "preview" then
      self_:exit_preview()
    else
      self_:close()
    end
  end
  self:map(both, { "n" }, m.close, close_or_back)
  self:map(both, { "n" }, "<Esc>", close_or_back)

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
    if self_.mode == "preview" then
      -- already replacing: jump to the Replace field to edit the term
      self_:focus()
      pcall(vim.api.nvim_win_set_cursor, self_.form_win, { 2, #(self_.values.replace or "") })
      vim.cmd("startinsert!")
    else
      self_:enter_preview()
    end
  end)

  -- form editing guards ------------------------------------------------
  -- Block backspace at column 1 so a field never merges into the one above
  -- (the old "layout collapses on backspace" bug). Needs expr so we can
  -- conditionally swallow the key.
  vim.keymap.set("i", "<BS>", function()
    return vim.fn.col(".") <= 1 and "" or "<BS>"
  end, { buffer = self.form_buf, expr = true, replace_keycodes = true, nowait = true, silent = true })
  -- <CR> in the form jumps to results instead of inserting a newline.
  self:map({ self.form_buf }, { "i", "n" }, "<CR>", function()
    self_:goto_results()
  end)
  -- Tab / Shift-Tab switch focus between the form (top) and results (bottom).
  -- Field and match selection is done with the arrow keys / j-k, so Tab is
  -- free to hop panes (never inserts a literal tab in the form).
  self:map(both, { "n", "i" }, "<Tab>", function()
    self_:toggle_pane()
  end)
  self:map(both, { "n", "i" }, "<S-Tab>", function()
    self_:toggle_pane()
  end)
  -- Block normal-mode line-structure edits in the form.
  for _, lhs in ipairs({ "o", "O", "J", "dd" }) do
    self:map({ self.form_buf }, { "n" }, lhs, function() end)
  end

  -- results/preview-only ------------------------------------------------
  self:map({ self.res_buf }, { "n" }, m.open, function()
    if self_.mode == "preview" then
      self_:apply()
    else
      self_:open_selected("edit")
    end
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
  -- Space: fold/unfold the file group under the cursor (search); toggle the
  -- file's apply state (preview).
  self:map({ self.res_buf }, { "n" }, "<Space>", function()
    if self_.mode == "preview" then
      self_:toggle_preview_file()
    else
      self_:toggle_fold()
    end
  end)
  self:map({ self.res_buf }, { "n" }, "<C-a>", function()
    if self_.mode == "preview" then
      self_:select_all(true)
    end
  end)
  self:map({ self.res_buf }, { "n" }, m.open_split, function()
    if self_.mode == "preview" then
      self_:select_all(false)
    else
      self_:open_selected("split")
    end
  end)
  self:map({ self.res_buf }, { "n" }, m.to_quickfix, function()
    self_:to_quickfix()
  end)

  -- window hop: from form, <C-j> to results; from results, <C-k> to form
  self:map({ self.form_buf }, { "n", "i" }, "<C-j>", function()
    self_:goto_results()
  end)
  self:map({ self.res_buf }, { "n" }, "<C-k>", function()
    self_:focus()
    vim.cmd("startinsert!")
  end)
end

function Panel:goto_results()
  if self.res_win and vim.api.nvim_win_is_valid(self.res_win) then
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(self.res_win)
  end
end

-- Toggle focus between the form (top, insert-ready) and the results (bottom).
function Panel:toggle_pane()
  if not self:is_open() then
    return
  end
  local in_results = self.res_win
    and vim.api.nvim_win_is_valid(self.res_win)
    and vim.api.nvim_get_current_win() == self.res_win
  if in_results then
    self:focus()
    vim.cmd("startinsert!")
  else
    self:goto_results()
  end
end

function Panel:setup_autocmds()
  local grp = vim.api.nvim_create_augroup("PowerFinder_" .. self.form_buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = grp,
    buffer = self.form_buf,
    callback = function()
      self:normalize_form()
      -- Refresh labels/placeholders/chips every keystroke so the empty-field
      -- placeholders appear and disappear as the user types.
      self:apply_form_marks()
      if self.mode == "preview" then
        self:schedule_replace()
      else
        self:schedule_search()
      end
    end,
  })
  -- The Replace field is locked in search mode: bounce the cursor off it so it
  -- can only be edited after entering replace mode with C-d.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = grp,
    buffer = self.form_buf,
    callback = function()
      if self.mode ~= "search" or not (self.form_win and vim.api.nvim_win_is_valid(self.form_win)) then
        return
      end
      local row = vim.api.nvim_win_get_cursor(self.form_win)[1]
      if row == 2 then
        local target = (self._form_prev_row and self._form_prev_row < 2) and 3 or 1
        local line = vim.api.nvim_buf_get_lines(self.form_buf, target - 1, target, false)[1] or ""
        pcall(vim.api.nvim_win_set_cursor, self.form_win, { target, #line })
        self._form_prev_row = target
      else
        self._form_prev_row = row
      end
    end,
  })
  -- close everything if either window is left/closed
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(ev)
      local w = tonumber(ev.match)
      if not self.closing and (w == self.form_win or w == self.res_win) then
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
