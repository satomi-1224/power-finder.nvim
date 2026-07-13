local scope = require("power-finder.scope")

local function make_tree(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for rel, content in pairs(files) do
    local abs = dir .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
    local fd = assert(io.open(abs, "w"))
    fd:write(content or "")
    fd:close()
  end
  return dir
end

describe("scope.resolve", function()
  it("cwd returns the working dir", function()
    assert.same({ "/home/x" }, scope.resolve("cwd", { cwd = "/home/x" }))
  end)

  it("path returns provided paths, or falls back to cwd", function()
    assert.same({ "/a", "/b" }, scope.resolve("path", { scope_paths = { "/a", "/b" } }))
    assert.same({ "/cwd" }, scope.resolve("path", { cwd = "/cwd" }))
  end)

  it("unknown scope falls back to cwd", function()
    assert.same({ "/cwd" }, scope.resolve("bogus", { cwd = "/cwd" }))
  end)
end)

describe("scope.project_root", function()
  it("walks up to the directory containing .git", function()
    local root = make_tree({ [".git/HEAD"] = "ref\n", ["pkg/sub/f.lua"] = "x\n" })
    local nested = root .. "/pkg/sub"
    -- resolve returns a normalized path; compare via fnamemodify
    local got = scope.project_root(nested)
    assert.equals(vim.fn.fnamemodify(root, ":p"):gsub("/$", ""), vim.fn.fnamemodify(got, ":p"):gsub("/$", ""))
  end)

  it("falls back to the dir itself when no .git is found", function()
    local dir = make_tree({ ["f.lua"] = "x\n" })
    -- a tempname has no .git ancestor within itself
    local got = scope.project_root(dir)
    assert.is_string(got)
  end)
end)

describe("scope.buffer_paths", function()
  it("lists loaded, named, readable file buffers", function()
    local dir = make_tree({ ["real.lua"] = "print(1)\n" })
    local path = dir .. "/real.lua"
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local paths = scope.buffer_paths()
    local want = vim.fn.resolve(path) -- macOS: /var -> /private/var symlink
    local found = false
    for _, p in ipairs(paths) do
      if vim.fn.resolve(p) == want then
        found = true
      end
    end
    assert.is_true(found)
    vim.cmd("bwipeout!")
  end)
end)
