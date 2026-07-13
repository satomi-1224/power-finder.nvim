-- User configuration with sane defaults.
local M = {}

M.defaults = {
  -- The key that opens the finder (set to false to skip the default mapping).
  keymap = "<leader>sf",

  layout = {
    width = 0.82, -- fraction of columns
    height = 0.86, -- fraction of lines
    border = "rounded",
    form_height = 5, -- number of form fields
  },

  search = {
    debounce_ms = 120,
    min_query = 1,
    max_results = 10000,
    max_columns = 4096,
    case = "smart", -- "smart" | "sensitive" | "ignore"
    hidden = false,
    no_ignore = false,
  },

  -- Initial state of a freshly opened finder.
  defaults = {
    include = "",
    exclude = "**/.git/**",
    scope = "project", -- "project" | "cwd" | "buffers" | "path"
    regex = true,
    word = false,
  },

  replace = {
    write_buffers = true, -- write modified open buffers after applying
  },

  fzf = {
    -- Use fzf-lua for the scope path picker when available.
    use_for_scope_picker = true,
  },

  rg = "rg",

  -- In-panel key mappings (buffer-local).
  mappings = {
    close = "q",
    toggle_regex = "<C-r>",
    toggle_case = "<C-c>",
    toggle_word = "<C-w>",
    scope_picker = "<C-s>",
    open = "<CR>",
    open_split = "<C-x>",
    open_vsplit = "<C-v>",
    fold = "za", -- toggle a file group in the results (Tab now switches panes)
    to_quickfix = "<C-q>",
    replace_preview = "<M-CR>",
    -- Tab / Shift-Tab switch focus between the form and results panes.
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts? table
---@return table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
