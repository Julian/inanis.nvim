has_lean3 := if `leanpkg help 2>&1 >/dev/null; echo $?` == "0" { "true" } else { "false" }

inanis := justfile_directory() + "/lua/inanis"

suite := justfile_directory() + "/tests"
init_lua := suite + "/minimal_init.lua"
tests := suite + "/inanis"

# Run the inanis.nvim test suite.
test:
    nvim --headless -u {{ init_lua }} -c 'lua require("inanis").run{ specs = { "{{ tests }}" }, minimal_init = "{{ init_lua }}" }'

# Lint inanis.nvim for style.
lint:
    luacheck {{ inanis }}
