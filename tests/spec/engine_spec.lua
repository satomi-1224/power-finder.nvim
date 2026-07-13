local engine = require("power-finder.engine")

-- helper: find index of `needle` in list, or nil
local function idx(list, needle)
  for i, v in ipairs(list) do
    if v == needle then
      return i
    end
  end
  return nil
end

-- helper: does list contain the ordered adjacent pair a,b ?
local function has_pair(list, a, b)
  for i = 1, #list - 1 do
    if list[i] == a and list[i + 1] == b then
      return true
    end
  end
  return false
end

describe("engine.build_args", function()
  it("always emits --json first", function()
    local a = engine.build_args({ query = "x" })
    assert.equals("--json", a[1])
  end)

  it("defaults to smart-case, regex on, max-columns 4096", function()
    local a = engine.build_args({ query = "foo" })
    assert.is_not_nil(idx(a, "--smart-case"))
    assert.is_nil(idx(a, "--fixed-strings"))
    assert.is_true(has_pair(a, "--max-columns", "4096"))
    assert.is_true(has_pair(a, "--regexp", "foo"))
  end)

  it("emits fixed-strings when regex is false", function()
    local a = engine.build_args({ query = "a.b", regex = false })
    assert.is_not_nil(idx(a, "--fixed-strings"))
  end)

  it("keeps regex when regex is true or nil", function()
    assert.is_nil(idx(engine.build_args({ query = "x", regex = true }), "--fixed-strings"))
    assert.is_nil(idx(engine.build_args({ query = "x" }), "--fixed-strings"))
  end)

  it("maps case modes", function()
    assert.is_not_nil(idx(engine.build_args({ query = "x", case = "sensitive" }), "--case-sensitive"))
    assert.is_not_nil(idx(engine.build_args({ query = "x", case = "ignore" }), "--ignore-case"))
  end)

  it("errors on unknown case mode", function()
    assert.has_error(function()
      engine.build_args({ query = "x", case = "bogus" })
    end)
  end)

  it("adds word-regexp, hidden, no-ignore when set", function()
    local a = engine.build_args({ query = "x", word = true, hidden = true, no_ignore = true })
    assert.is_not_nil(idx(a, "--word-regexp"))
    assert.is_not_nil(idx(a, "--hidden"))
    assert.is_not_nil(idx(a, "--no-ignore"))
  end)

  it("omits max-columns when <= 0", function()
    local a = engine.build_args({ query = "x", max_columns = 0 })
    assert.is_nil(idx(a, "--max-columns"))
  end)

  it("emits include globs verbatim and exclude globs negated", function()
    local a = engine.build_args({
      query = "x",
      include_globs = { "*.ts", "*.tsx" },
      exclude_globs = { "**/node_modules/**" },
    })
    assert.is_true(has_pair(a, "--glob", "*.ts"))
    assert.is_true(has_pair(a, "--glob", "*.tsx"))
    assert.is_true(has_pair(a, "--glob", "!**/node_modules/**"))
  end)

  it("includes --replace only when requested", function()
    local plain = engine.build_args({ query = "x", replace = "y" })
    assert.is_nil(idx(plain, "--replace"))

    local repl = engine.build_args({ query = "x", replace = "y" }, { with_replace = true })
    assert.is_true(has_pair(repl, "--replace", "y"))
  end)

  it("allows an empty replacement (delete matches)", function()
    local a = engine.build_args({ query = "x", replace = "" }, { with_replace = true })
    assert.is_true(has_pair(a, "--replace", ""))
  end)

  it("guards paths behind -- and preserves order", function()
    local a = engine.build_args({ query = "x", paths = { "src", "lib" } })
    local dd = idx(a, "--")
    assert.is_not_nil(dd)
    assert.equals("src", a[dd + 1])
    assert.equals("lib", a[dd + 2])
    -- pattern must come before the path separator
    assert.is_true(idx(a, "--regexp") < dd)
  end)

  it("omits -- when there are no paths", function()
    local a = engine.build_args({ query = "x" })
    assert.is_nil(idx(a, "--"))
  end)

  it("passes a pattern starting with dash safely via --regexp", function()
    local a = engine.build_args({ query = "-foo" })
    assert.is_true(has_pair(a, "--regexp", "-foo"))
  end)
end)
