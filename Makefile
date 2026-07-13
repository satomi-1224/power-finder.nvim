.PHONY: test test-file deps lint clean

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

clean:
	rm -rf $(PLENARY)
