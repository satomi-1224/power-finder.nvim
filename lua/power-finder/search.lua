-- Async ripgrep execution with debounce + cancellation.
-- Pure argument/parse logic lives in engine.lua / parser.lua; this module only
-- owns the process side-effects.
local engine = require("power-finder.engine")
local parser = require("power-finder.parser")

local M = {}

-- Overridable for tests / custom binaries.
M.rg = "rg"

--- Run ripgrep once, asynchronously.
---@param query pf.Query
---@param opts { cwd?:string, with_replace?:boolean, max_results?:integer }
---@param cb fun(err:string?, results:pf.Results?)
---@return table job  handle with :kill()
function M.run(query, opts, cb)
  opts = opts or {}
  local args = engine.build_args(query, { with_replace = opts.with_replace })
  local cmd = { M.rg }
  vim.list_extend(cmd, args)

  return vim.system(cmd, { text = true, cwd = opts.cwd }, function(res)
    -- ripgrep exit codes: 0 = matches found, 1 = no matches, 2 = real error.
    if res.code == 2 then
      local msg = (res.stderr and res.stderr ~= "") and res.stderr or "ripgrep failed"
      vim.schedule(function()
        cb(vim.trim(msg), nil)
      end)
      return
    end
    local lines = vim.split(res.stdout or "", "\n", { plain = true })
    local results = parser.parse(lines, { max_results = opts.max_results })
    vim.schedule(function()
      cb(nil, results)
    end)
  end)
end

------------------------------------------------------------------------------
-- Debounced controller: coalesces rapid keystrokes and drops stale results.
------------------------------------------------------------------------------

---@class pf.Debounced
local Debounced = {}
Debounced.__index = Debounced

---@param opts? { delay?:integer, min_query?:integer, max_results?:integer }
---@return pf.Debounced
function M.debounced(opts)
  opts = opts or {}
  return setmetatable({
    delay = opts.delay or 120,
    min_query = opts.min_query or 1,
    max_results = opts.max_results,
    _timer = nil,
    _job = nil,
    _gen = 0,
  }, Debounced)
end

local EMPTY = { files = {}, total = 0, truncated = false }

--- Cancel any pending timer and in-flight ripgrep process.
function Debounced:cancel()
  if self._timer then
    self._timer:stop()
    if not self._timer:is_closing() then
      self._timer:close()
    end
    self._timer = nil
  end
  if self._job then
    pcall(function()
      self._job:kill(9)
    end)
    self._job = nil
  end
end

--- Request a (debounced) search. Later requests supersede earlier ones; results
--- from a superseded generation are discarded.
---@param query pf.Query & { cwd?:string, with_replace?:boolean }
---@param cb fun(err:string?, results:pf.Results?)
function Debounced:request(query, cb)
  self:cancel()

  if #(query.query or "") < self.min_query then
    cb(nil, vim.deepcopy(EMPTY))
    return
  end

  self._gen = self._gen + 1
  local gen = self._gen

  self._timer = vim.uv.new_timer()
  self._timer:start(
    self.delay,
    0,
    vim.schedule_wrap(function()
      if self._timer then
        self._timer:stop()
        if not self._timer:is_closing() then
          self._timer:close()
        end
        self._timer = nil
      end
      if gen ~= self._gen then
        return
      end
      self._job = M.run(query, {
        cwd = query.cwd,
        with_replace = query.with_replace,
        max_results = self.max_results,
      }, function(err, results)
        if gen ~= self._gen then
          return -- a newer request already superseded this one
        end
        self._job = nil
        cb(err, results)
      end)
    end)
  )
end

return M
