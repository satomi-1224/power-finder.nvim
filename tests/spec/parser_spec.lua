local parser = require("power-finder.parser")

-- Real ripgrep --json lines (captured from `rg --json`).
local function line(tbl)
  return vim.json.encode(tbl)
end

local BEGIN_A = line({ type = "begin", data = { path = { text = "a.ts" } } })
local MATCH_A1 = line({
  type = "match",
  data = {
    path = { text = "a.ts" },
    lines = { text = "export function handleRequest(req) {\n" },
    line_number = 1,
    submatches = { { match = { text = "handleRequest" }, start = 16, ["end"] = 29 } },
  },
})
local MATCH_A2 = line({
  type = "match",
  data = {
    path = { text = "a.ts" },
    lines = { text = "  return handleRequest(x)\n" },
    line_number = 2,
    submatches = { { match = { text = "handleRequest" }, start = 9, ["end"] = 22 } },
  },
})
local END_A = line({ type = "end", data = { path = { text = "a.ts" } } })
local SUMMARY = line({
  type = "summary",
  data = { stats = { elapsed = { secs = 0, nanos = 154000 }, matches = 2 } },
})

describe("parser.parse", function()
  it("groups matches by file in encounter order", function()
    local r = parser.parse({ BEGIN_A, MATCH_A1, MATCH_A2, END_A, SUMMARY })
    assert.equals(1, #r.files)
    assert.equals("a.ts", r.files[1].path)
    assert.equals(2, #r.files[1].matches)
    assert.equals(2, r.total)
  end)

  it("extracts line numbers, stripped text, and byte offsets", function()
    local r = parser.parse({ BEGIN_A, MATCH_A1, END_A })
    local m = r.files[1].matches[1]
    assert.equals(1, m.lnum)
    assert.equals("export function handleRequest(req) {", m.text) -- newline stripped
    assert.equals(16, m.submatches[1].start)
    assert.equals(29, m.submatches[1].finish)
    assert.equals("handleRequest", m.submatches[1].text)
  end)

  it("reports rg elapsed time from the summary", function()
    local r = parser.parse({ BEGIN_A, MATCH_A1, END_A, SUMMARY })
    assert.equals(154, r.elapsed_us) -- 154000 ns -> 154 us
  end)

  it("drops files that produced no matches", function()
    local r = parser.parse({ BEGIN_A, END_A })
    assert.equals(0, #r.files)
  end)

  it("ignores blank lines and malformed json", function()
    local r = parser.parse({ "", "not json", BEGIN_A, MATCH_A1, END_A })
    assert.equals(1, #r.files)
  end)

  it("captures rg-provided replacements when present", function()
    local repl = line({
      type = "match",
      data = {
        path = { text = "a.ts" },
        lines = { text = "handleRequest()\n" },
        line_number = 1,
        submatches = {
          {
            match = { text = "handleRequest" },
            replacement = { text = "dispatchRequest" },
            start = 0,
            ["end"] = 13,
          },
        },
      },
    })
    local r = parser.parse({ BEGIN_A, repl, END_A })
    assert.equals("dispatchRequest", r.files[1].matches[1].submatches[1].replacement)
  end)

  it("truncates at max_results and flags it", function()
    local r = parser.parse({ BEGIN_A, MATCH_A1, MATCH_A2, END_A }, { max_results = 1 })
    assert.is_true(r.truncated)
    assert.equals(1, r.total)
    assert.equals(1, #r.files[1].matches) -- second match dropped
  end)

  it("handles a multibyte (Japanese) line with byte offsets", function()
    local jp = line({
      type = "match",
      data = {
        path = { text = "a.ts" },
        lines = { text = "日本語のマッチ handleRequest あり\n" },
        line_number = 3,
        submatches = { { match = { text = "handleRequest" }, start = 22, ["end"] = 35 } },
      },
    })
    local r = parser.parse({ BEGIN_A, jp, END_A })
    local m = r.files[1].matches[1]
    assert.equals(22, m.submatches[1].start)
    -- the byte slice [start,end) must be exactly the match
    assert.equals("handleRequest", m.text:sub(m.submatches[1].start + 1, m.submatches[1].finish))
  end)
end)
