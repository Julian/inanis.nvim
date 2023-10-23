.PHONY: test
test:
	nvim --headless -u ./tests/minimal_init.lua -c 'lua require("inanis").run{ specs = { "tests/inanis" }, minimal_init = "tests/minimal_init.lua" }'

lint:
	luacheck lua/inanis
