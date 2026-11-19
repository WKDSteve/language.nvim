std = "luajit"
globals = { "vim" }
-- LuaCATS `fun(...)` annotations for callback-heavy provider interfaces run
-- long; wrapping them hurts readability more than it helps -- and stylua does
-- not reflow comments, so the limit only ever produced findings with no clean
-- fix. Line width for code is stylua's job (column_width in stylua.toml).
max_line_length = false
-- TESTS/sheets_spec.lua is busted style (describe/it, `.testing.lua` sets its dialect); every other spec runs on
-- TESTS/harness.lua.
files["TESTS/sheets_spec.lua"] = { std = "+busted" }
