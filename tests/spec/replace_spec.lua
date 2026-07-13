local replace = require("power-finder.replace")

describe("replace.render_replaced_line", function()
  it("replaces a single submatch", function()
    -- "export function handleRequest(req) {" , handleRequest at [16,29)
    local text = "export function handleRequest(req) {"
    local subs = { { start = 16, finish = 29, replacement = "dispatchRequest" } }
    assert.equals("export function dispatchRequest(req) {", replace.render_replaced_line(text, subs))
  end)

  it("replaces multiple submatches on one line, left to right", function()
    local text = "foo and foo again"
    local subs = {
      { start = 0, finish = 3, replacement = "bar" },
      { start = 8, finish = 11, replacement = "bar" },
    }
    assert.equals("bar and bar again", replace.render_replaced_line(text, subs))
  end)

  it("handles an empty replacement (deletion)", function()
    local text = "aXb"
    local subs = { { start = 1, finish = 2, replacement = "" } }
    assert.equals("ab", replace.render_replaced_line(text, subs))
  end)

  it("is multibyte-safe using byte offsets", function()
    -- "日本語のマッチ handleRequest あり", match at byte [22,35)
    local text = "日本語のマッチ handleRequest あり"
    local subs = { { start = 22, finish = 35, replacement = "dispatchRequest" } }
    assert.equals("日本語のマッチ dispatchRequest あり", replace.render_replaced_line(text, subs))
  end)

  it("ignores submatches without a replacement", function()
    local text = "keep me"
    local subs = { { start = 0, finish = 4 } } -- no replacement field
    assert.equals("keep me", replace.render_replaced_line(text, subs))
  end)
end)

describe("replace.build_preview", function()
  local function results_with(matches)
    return { files = { { path = "a.ts", matches = matches, collapsed = false } } }
  end

  it("builds old/new pairs and counts changes", function()
    local results = results_with({
      {
        lnum = 1,
        text = "handleRequest()",
        submatches = { { start = 0, finish = 13, replacement = "dispatchRequest" } },
      },
    })
    local preview = replace.build_preview(results)
    assert.equals(1, #preview)
    assert.equals("a.ts", preview[1].path)
    assert.equals(1, preview[1].changes)
    assert.is_true(preview[1].selected)
    assert.equals("handleRequest()", preview[1].lines[1].old)
    assert.equals("dispatchRequest()", preview[1].lines[1].new)
  end)

  it("skips lines whose replacement equals the original", function()
    local results = results_with({
      {
        lnum = 1,
        text = "foo",
        submatches = { { start = 0, finish = 3, replacement = "foo" } },
      },
    })
    assert.equals(0, #replace.build_preview(results))
  end)

  it("drops files with no effective changes", function()
    local results = results_with({
      { lnum = 1, text = "foo", submatches = { { start = 0, finish = 3 } } }, -- no replacement
    })
    assert.equals(0, #replace.build_preview(results))
  end)
end)

describe("replace.summarize", function()
  it("counts only selected files", function()
    local preview = {
      { path = "a", changes = 2, selected = true, lines = {} },
      { path = "b", changes = 3, selected = false, lines = {} },
      { path = "c", changes = 1, selected = true, lines = {} },
    }
    local s = replace.summarize(preview)
    assert.equals(2, s.files)
    assert.equals(3, s.total_files)
    assert.equals(3, s.changes) -- 2 + 1
  end)
end)
