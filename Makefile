.PHONY: test deps fmt lint clean

STYLUA_TARGETS := lua/ plugin/ tests/

PLENARY := tests/deps/plenary.nvim

deps: $(PLENARY)
$(PLENARY):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

# Run the whole suite headlessly. Exits non-zero if any spec fails.
# Uses an in-process runner (tests/run.lua) instead of PlenaryBusted*, which
# spawns child jobs that hang under headless nvim in some environments.
test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-l tests/run.lua

# Format Lua sources in place (requires stylua).
fmt:
	stylua $(STYLUA_TARGETS)

# Verify formatting without writing (matches the CI lint job).
lint:
	stylua --check $(STYLUA_TARGETS)

clean:
	rm -rf $(PLENARY)
