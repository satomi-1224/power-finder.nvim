-- End-to-end tests that shell out to the real ripgrep binary and touch real
-- files. They exercise engine → search → parser → replace as a pipeline.

local search = require("power-finder.search")
local replace = require("power-finder.replace")

-- Create a throwaway directory populated with `files` (map path -> content).
local function make_tree(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for rel, content in pairs(files) do
    local abs = dir .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
    local fd = assert(io.open(abs, "w"))
    fd:write(content)
    fd:close()
  end
  return dir
end

local function read(path)
  local fd = assert(io.open(path, "r"))
  local c = fd:read("*a")
  fd:close()
  return c
end

-- Run an async fn(cb) and block until cb fires (or time out).
local function await(fn, timeout)
  local done, result = false, nil
  fn(function(...)
    result = { ... }
    done = true
  end)
  local ok = vim.wait(timeout or 5000, function()
    return done
  end, 20)
  assert(ok, "timed out waiting for async result")
  return unpack(result)
end

local has_rg = vim.fn.executable("rg") == 1

describe("integration: search.run", function()
  if not has_rg then
    pending("ripgrep not available")
    return
  end

  it("finds matches grouped by file", function()
    local dir = make_tree({
      ["a.ts"] = "export function handleRequest(req) {\n  return handleRequest(req)\n}\n",
      ["sub/b.ts"] = "const x = 1\nhandleRequest()\n",
      ["c.md"] = "handleRequest documented here\n",
    })
    local err, results = await(function(cb)
      search.run({ query = "handleRequest", paths = { dir } }, {}, cb)
    end)
    assert.is_nil(err)
    assert.equals(3, #results.files)
    assert.equals(4, results.total) -- 2 + 1 + 1
  end)

  it("respects include globs", function()
    local dir = make_tree({
      ["a.ts"] = "handleRequest\n",
      ["c.md"] = "handleRequest\n",
    })
    local err, results = await(function(cb)
      search.run({ query = "handleRequest", paths = { dir }, include_globs = { "*.ts" } }, {}, cb)
    end)
    assert.is_nil(err)
    assert.equals(1, #results.files)
    assert.is_true(results.files[1].path:match("%.ts$") ~= nil)
  end)

  it("respects exclude globs", function()
    local dir = make_tree({
      ["a.ts"] = "handleRequest\n",
      ["node_modules/dep.ts"] = "handleRequest\n",
    })
    local err, results = await(function(cb)
      search.run({ query = "handleRequest", paths = { dir }, exclude_globs = { "**/node_modules/**" } }, {}, cb)
    end)
    assert.is_nil(err)
    assert.equals(1, #results.files)
  end)

  it("treats a fixed-string query literally", function()
    local dir = make_tree({ ["a.txt"] = "value = a.b\nvalue = axb\n" })
    local err, results = await(function(cb)
      search.run({ query = "a.b", regex = false, paths = { dir } }, {}, cb)
    end)
    assert.is_nil(err)
    assert.equals(1, results.total) -- only "a.b", not "axb"
  end)

  it("returns empty (not error) when nothing matches", function()
    local dir = make_tree({ ["a.txt"] = "nothing here\n" })
    local err, results = await(function(cb)
      search.run({ query = "zzzznotfound", paths = { dir } }, {}, cb)
    end)
    assert.is_nil(err)
    assert.equals(0, #results.files)
  end)

  it("matches multibyte content with correct byte offsets", function()
    local dir = make_tree({ ["jp.txt"] = "日本語 handleRequest あり\n" })
    local err, results = await(function(cb)
      search.run({ query = "handleRequest", paths = { dir } }, {}, cb)
    end)
    assert.is_nil(err)
    local m = results.files[1].matches[1]
    assert.equals("handleRequest", m.text:sub(m.submatches[1].start + 1, m.submatches[1].finish))
  end)
end)

describe("integration: replace pipeline", function()
  if not has_rg then
    pending("ripgrep not available")
    return
  end

  it("computes a capture-aware preview via rg -r", function()
    local dir = make_tree({ ["a.ts"] = "handleRequest(1)\nhandleResponse(2)\n" })
    -- $1 capture reference handled by ripgrep's rust regex.
    local err, preview = await(function(cb)
      replace.gather_preview({ query = "handle(\\w+)", replace = "process$1", paths = { dir } }, {}, cb)
    end)
    assert.is_nil(err)
    assert.equals(1, #preview)
    assert.equals("processRequest(1)", preview[1].lines[1].new)
    assert.equals("processResponse(2)", preview[1].lines[2].new)
  end)

  it("applies selected files and leaves deselected ones untouched", function()
    local dir = make_tree({
      ["x.ts"] = "foo()\nfoo()\n",
      ["y.ts"] = "foo()\n",
    })
    local _, preview = await(function(cb)
      replace.gather_preview({ query = "foo", replace = "bar", paths = { dir } }, {}, cb)
    end)
    -- deselect y.ts
    for _, f in ipairs(preview) do
      if f.path:match("y%.ts$") then
        f.selected = false
      end
    end
    local res = replace.apply(preview, { write_buffers = false })
    assert.equals(1, res.files)
    assert.equals(2, res.changes)
    assert.equals(0, #res.skipped)
    assert.equals("bar()\nbar()\n", read(dir .. "/x.ts"))
    assert.equals("foo()\n", read(dir .. "/y.ts")) -- untouched
  end)

  it("skips a file that changed on disk since the search (stale guard)", function()
    local dir = make_tree({ ["z.ts"] = "foo()\n" })
    local _, preview = await(function(cb)
      replace.gather_preview({ query = "foo", replace = "bar", paths = { dir } }, {}, cb)
    end)
    -- external edit invalidates the recorded `old` line
    local fd = assert(io.open(dir .. "/z.ts", "w"))
    fd:write("something else entirely\n")
    fd:close()

    local res = replace.apply(preview, { write_buffers = false })
    assert.equals(0, res.files)
    assert.equals(1, #res.skipped)
    assert.equals("something else entirely\n", read(dir .. "/z.ts")) -- preserved
  end)
end)

describe("integration: debounced controller", function()
  if not has_rg then
    pending("ripgrep not available")
    return
  end

  it("only delivers the final request when called rapidly", function()
    local dir = make_tree({
      ["a.txt"] = "alpha\n",
      ["b.txt"] = "beta\n",
    })
    local d = search.debounced({ delay = 30 })
    local calls = {}
    -- fire three requests in quick succession; only the last should resolve
    d:request({ query = "alp", paths = { dir } }, function() end)
    d:request({ query = "bet", paths = { dir } }, function() end)
    local err, results = await(function(cb)
      d:request({ query = "beta", paths = { dir } }, function(e, r)
        calls[#calls + 1] = true
        cb(e, r)
      end)
    end)
    assert.is_nil(err)
    assert.equals(1, results.total)
    assert.equals(1, #calls)
  end)

  it("short-circuits queries below min_query without running rg", function()
    local d = search.debounced({ delay = 10, min_query = 2 })
    local err, results = await(function(cb)
      d:request({ query = "a", paths = { "/tmp" } }, cb)
    end)
    assert.is_nil(err)
    assert.equals(0, #results.files)
  end)
end)
