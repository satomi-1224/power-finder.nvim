-- Optional fzf-lua integration: a nicer scope/path picker when fzf-lua is
-- installed. Everything degrades to vim.ui.select/input when it isn't.
local M = {}

function M.available()
  return pcall(require, "fzf-lua")
end

--- Pick a search scope; for "path", pick a directory with fzf-lua.
---@param panel pf.Panel
function M.pick_scope(panel)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return false
  end

  local kinds = { "project", "cwd", "buffers", "path" }
  fzf.fzf_exec(kinds, {
    prompt = "Scope> ",
    actions = {
      ["default"] = function(selected)
        local choice = selected and selected[1]
        if not choice then
          return
        end
        if choice == "path" then
          M.pick_path(panel, fzf)
        else
          panel:set_scope(choice)
        end
      end,
    },
  })
  return true
end

--- Directory picker. Uses `fd` if present, else `find`.
---@param panel pf.Panel
---@param fzf table
function M.pick_path(panel, fzf)
  local cmd
  if vim.fn.executable("fd") == 1 then
    cmd = "fd --type d --hidden --exclude .git"
  else
    cmd = "find . -type d -not -path '*/.git/*'"
  end
  fzf.fzf_exec(cmd, {
    prompt = "Path> ",
    cwd = panel.cwd,
    actions = {
      ["default"] = function(selected)
        local dir = selected and selected[1]
        if dir and dir ~= "" then
          local abs = vim.fn.fnamemodify(panel.cwd .. "/" .. dir, ":p")
          panel:set_scope("path", { abs })
        end
      end,
    },
  })
end

return M
