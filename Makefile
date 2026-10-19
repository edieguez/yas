LUA ?= luajit

.PHONY: test test-verbose test-all

# Run the suite with LuaJIT (what mpv normally embeds).
test:
	$(LUA) tests/run.lua $(SPEC)

# Same, listing every test and why each known bug still fails.
test-verbose:
	YAS_VERBOSE=1 $(LUA) tests/run.lua $(SPEC)

# Run under every interpreter mpv can be built with that is installed here.
test-all:
	@status=0; for l in luajit lua5.1 lua5.2 lua5.3 lua5.4; do \
		if command -v $$l >/dev/null 2>&1; then \
			echo "== $$l"; out=$$($$l tests/run.lua $(SPEC)) || status=1; echo "$$out" | tail -1; \
		fi; \
	done; exit $$status
