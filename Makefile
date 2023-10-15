.PHONY: test
test:
	nvim --headless -u ./tests/minimal_init.lua -c 'lua require("inanis.test_harness").test_directory("tests/inanis", { minimal_init = "tests/minimal_init.lua" })'

lint:
	luacheck lua/inanis
