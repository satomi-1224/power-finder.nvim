-- Self-contained headless test runner.
--
-- PlenaryBustedDirectory spawns child jobs that hang in this headless setup, so
-- we run everything in-process: reuse luassert for assertions, provide a tiny
-- describe/it/before_each, execute every tests/spec/*.lua, print a TAP-ish
-- report and exit non-zero on any failure.

local assert = require("luassert")
_G.assert = assert

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local results = { pass = 0, fail = 0 }
local desc_stack = {}
local before_stack = {}

function _G.describe(name, fn)
  table.insert(desc_stack, name)
  table.insert(before_stack, {})
  local ok, err = pcall(fn)
  if not ok then
    io.write("not ok - <describe error> " .. name .. "\n    " .. tostring(err) .. "\n")
    results.fail = results.fail + 1
  end
  table.remove(desc_stack)
  table.remove(before_stack)
end

function _G.before_each(fn)
  local level = before_stack[#before_stack]
  level[#level + 1] = fn
end

local function run_befores()
  for _, level in ipairs(before_stack) do
    for _, fn in ipairs(level) do
      fn()
    end
  end
end

function _G.it(name, fn)
  local full = table.concat(desc_stack, " › ") .. " › " .. name
  local ok, err = xpcall(function()
    run_befores()
    fn()
  end, debug.traceback)
  if ok then
    results.pass = results.pass + 1
    io.write("ok   - " .. full .. "\n")
  else
    results.fail = results.fail + 1
    io.write("FAIL - " .. full .. "\n")
    io.write("       " .. tostring(err):gsub("\n", "\n       ") .. "\n")
  end
end
_G.pending = function(name) io.write("skip - " .. name .. "\n") end

-- Discover and run specs.
local specs = vim.fn.glob(here .. "/spec/*.lua", false, true)
table.sort(specs)
io.write(("Running %d spec file(s)\n\n"):format(#specs))
for _, f in ipairs(specs) do
  local ok, err = pcall(dofile, f)
  if not ok then
    results.fail = results.fail + 1
    io.write("FAIL - <load " .. f .. ">\n       " .. tostring(err) .. "\n")
  end
end

io.write(("\n%d passed, %d failed\n"):format(results.pass, results.fail))
io.flush()
os.exit(results.fail == 0 and 0 or 1)
