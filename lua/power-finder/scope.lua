-- Resolve a scope selection into concrete ripgrep search paths.
local M = {}

--- Best-effort git project root for `dir`, falling back to `dir`.
---@param dir string
---@return string
function M.project_root(dir)
  local found = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  if found then
    return vim.fs.dirname(found)
  end
  return dir
end

--- Paths of loaded, named, on-disk buffers.
---@return string[]
function M.buffer_paths()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and vim.fn.filereadable(name) == 1 then
        out[#out + 1] = name
      end
    end
  end
  return out
end

--- Resolve a scope into a list of search paths.
---@param scope "project"|"cwd"|"buffers"|"path"
---@param state { cwd?:string, scope_paths?:string[] }
---@return string[]
function M.resolve(scope, state)
  state = state or {}
  local cwd = state.cwd or vim.fn.getcwd()
  if scope == "cwd" then
    return { cwd }
  elseif scope == "project" then
    return { M.project_root(cwd) }
  elseif scope == "buffers" then
    local bufs = M.buffer_paths()
    return #bufs > 0 and bufs or { cwd }
  elseif scope == "path" then
    local p = state.scope_paths
    if p and #p > 0 then
      return p
    end
    return { cwd }
  end
  return { cwd }
end

return M
