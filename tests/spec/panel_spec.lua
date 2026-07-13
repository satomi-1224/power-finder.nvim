-- Headless smoke tests for the panel: they open real (hidden) floating windows
-- and drive the same methods the key mappings call, so the UI wiring is
-- exercised even without a human at a terminal.

local config = require("power-finder.config")
local panel_mod = require("power-finder.panel")

local has_rg = vim.fn.executable("rg") == 1

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

local function wait_until(pred, timeout)
  return vim.wait(timeout or 4000, pred, 20)
end

local function contains(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return true
    end
  end
  return false
end

describe("panel", function()
  if not has_rg then
    pending("ripgrep not available")
    return
  end

  before_each(function()
    config.setup({})
    -- Ensure no panel leaked from a previously-failed test (open() reuses the
    -- current instance if one is still open, which would corrupt this test).
    if panel_mod._current then
      pcall(function()
        panel_mod._current:close()
      end)
    end
    -- Conditions persist across opens for the nvim session; clear between tests
    -- so each test starts from defaults.
    panel_mod._last_state = nil
  end)

  it("opens two valid floating windows", function()
    local dir = make_tree({ ["a.ts"] = "x\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    assert.is_true(vim.api.nvim_win_is_valid(p.form_win))
    assert.is_true(vim.api.nvim_win_is_valid(p.res_win))
    assert.is_false(vim.bo[p.res_buf].modifiable) -- results are read-only
    p:close()
    assert.is_false(p:is_open())
  end)

  it("renders grouped results for a query", function()
    local dir = make_tree({
      ["a.ts"] = "export function handleRequest() {}\n",
      ["b.ts"] = "handleRequest()\n",
    })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    p:_set_values({ search = "handleRequest" })
    local done = false
    p:_search_now(function()
      done = true
    end)
    assert.is_true(wait_until(function()
      return done
    end))
    local lines = p:_results_lines()
    assert.is_true(contains(lines, "2 matches"))
    assert.is_true(contains(lines, "a.ts"))
    assert.is_true(contains(lines, "handleRequest"))
    p:close()
  end)

  it("folds a file group, hiding its matches", function()
    local dir = make_tree({ ["a.ts"] = "handleRequest\nhandleRequest\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    p:_set_values({ search = "handleRequest" })
    local done = false
    p:_search_now(function()
      done = true
    end)
    wait_until(function()
      return done
    end)
    local before = #p:_results_lines()
    p.results.files[1].collapsed = true
    p:render_results()
    local after = #p:_results_lines()
    assert.is_true(after < before)
    p:close()
  end)

  it("cycles the case toggle through smart/sensitive/ignore", function()
    local dir = make_tree({ ["a.ts"] = "x\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    assert.equals("smart", p.toggles.case)
    p:toggle("case")
    assert.equals("sensitive", p.toggles.case)
    p:toggle("case")
    assert.equals("ignore", p.toggles.case)
    p:toggle("case")
    assert.equals("smart", p.toggles.case)
    p:close()
  end)

  it("enters replace mode and applies the change", function()
    local dir = make_tree({ ["a.ts"] = "handleRequest()\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    p:_set_values({ search = "handleRequest", replace = "dispatchRequest" })
    p:enter_preview()
    assert.equals("preview", p.mode)
    assert.is_true(wait_until(function()
      return contains(p:_results_lines(), "+dispatchRequest()")
    end))
    local lines = p:_results_lines()
    assert.is_true(contains(lines, "Replace:"))
    assert.is_true(contains(lines, "-handleRequest()"))

    p:apply()
    assert.equals("dispatchRequest()\n", read(dir .. "/a.ts"))
    assert.equals("search", p.mode) -- returned to search view
    p:close()
  end)

  it("updates the diff live when the replacement changes", function()
    local dir = make_tree({ ["a.ts"] = "handleRequest()\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    p:_set_values({ search = "handleRequest", replace = "foo" })
    p:enter_preview()
    assert.is_true(wait_until(function()
      return contains(p:_results_lines(), "+foo()")
    end))
    -- change the replacement term; the diff must follow live
    p:_set_values({ search = "handleRequest", replace = "bar" })
    p:schedule_replace()
    assert.is_true(wait_until(function()
      return contains(p:_results_lines(), "+bar()")
    end))
    assert.is_false(contains(p:_results_lines(), "+foo()"))
    p:close()
  end)

  it("populates the quickfix list", function()
    local dir = make_tree({ ["a.ts"] = "handleRequest\nhandleRequest\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    p:_set_values({ search = "handleRequest" })
    local done = false
    p:_search_now(function()
      done = true
    end)
    wait_until(function()
      return done
    end)
    p:to_quickfix()
    local qf = vim.fn.getqflist()
    assert.equals(2, #qf)
    pcall(vim.cmd, "cclose")
  end)

  it("folds the file group under the cursor (Space handler)", function()
    local dir = make_tree({ ["a.ts"] = "handleRequest\nhandleRequest\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    p:_set_values({ search = "handleRequest" })
    local done = false
    p:_search_now(function()
      done = true
    end)
    wait_until(function()
      return done
    end)
    local before = #p:_results_lines()
    -- line 3 is the file header; toggle_fold acts on the item under the cursor
    pcall(vim.api.nvim_win_set_cursor, p.res_win, { 3, 0 })
    p:toggle_fold()
    assert.is_true(#p:_results_lines() < before)
    p:toggle_fold()
    assert.equals(before, #p:_results_lines())
    p:close()
  end)

  it("remembers conditions across opens for the session", function()
    local dir = make_tree({ ["a.ts"] = "handleRequest\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    p:_set_values({ search = "handleRequest", include = "*.ts" })
    p:toggle("word")
    local word = p.toggles.word
    p:close()

    local p2 = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    assert.equals("handleRequest", p2.values.search)
    assert.equals("*.ts", p2.values.include)
    assert.equals(word, p2.toggles.word)
    p2:close()
  end)

  it("closes the panel after jumping to a match", function()
    local dir = make_tree({ ["a.ts"] = "handleRequest\n" })
    local p = panel_mod.open({ cwd = dir, scope = "path", scope_paths = { dir } })
    p:_set_values({ search = "handleRequest" })
    local done = false
    p:_search_now(function()
      done = true
    end)
    wait_until(function()
      return done
    end)
    -- line 4 is the first match (1 status, 2 blank, 3 file header, 4 match)
    pcall(vim.api.nvim_win_set_cursor, p.res_win, { 4, 0 })
    p:open_selected("edit")
    assert.is_false(p:is_open())
    assert.equals("a.ts", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    pcall(vim.cmd, "bwipeout!")
  end)
end)
