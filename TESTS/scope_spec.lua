-- TESTS/scope_spec.lua — language.scope: turning the words after a command
-- into the region it should act on, and handing back whatever was not a scope
-- word so the caller can still read its own arguments.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked(function()
    local scope = require("language.scope")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })

    -- The default ---------------------------------------------------------------
    local s, rest = scope.parse({}, { bufnr = buf })
    H.eq(s.kind, "buffer", "with no tokens, the scope is the buffer")
    H.eq(s.bufnr, buf, "the given buffer, not the current one")
    H.eq(#rest, 0, "and nothing is left over")

    -- Scope words ---------------------------------------------------------------
    H.eq(scope.parse({ "buffer" }, { bufnr = buf }).kind, "buffer", "an explicit buffer scope")

    local sel = scope.parse({ "selection" }, { bufnr = buf, line1 = 2, line2 = 3 })
    H.eq(sel.kind, "selection", "selection is recognised")
    H.eq(sel.range.s, 2, "and takes its start from the command's range")
    H.eq(sel.range.e, 3, "and its end")

    -- A selection without a range falls back to the whole buffer rather than an
    -- empty one: acting on nothing is the more surprising outcome.
    local no_range = scope.parse({ "selection" }, { bufnr = buf })
    H.eq(no_range.range.s, 1, "without a range it starts at line 1")
    H.eq(no_range.range.e, 4, "and ends at the last line")

    -- path= ---------------------------------------------------------------------
    local p = scope.parse({ "path=~/notes.md" }, { bufnr = buf })
    H.eq(p.kind, "path", "path= is its own scope kind")
    H.excludes(p.path, "~", "and the path is expanded, not passed through")

    -- SEC-34: a backtick span in the path must never run as a shell command
    -- substitution -- vim.fn.expand() would do exactly that; expand_path()
    -- only expands `~` and env vars, leaving everything else literal.
    local injected = scope.parse({ "path=`echo pwned`/x.md" }, { bufnr = buf })
    H.contains(injected.path, "`echo pwned`", "a backtick span is left literal, not shelled out")

    -- Leftover tokens ------------------------------------------------------------
    -- The caller's own arguments have to survive: `:Spellcheck de buffer` is a
    -- language *and* a scope, and the language must come back untouched.
    local _, args = scope.parse({ "de", "buffer" }, { bufnr = buf })
    H.eq(#args, 1, "a non-scope token is handed back")
    H.eq(args[1], "de", "unchanged")

    local _, many = scope.parse({ "de", "extra" }, { bufnr = buf })
    H.eq(#many, 2, "several of them keep their order")
    H.eq(many[1], "de", "first")
    H.eq(many[2], "extra", "second")

    -- Implicit selection ---------------------------------------------------------
    -- `:'<,'>Spellcheck` gives a range but names no scope; that has to mean the
    -- selection, not the whole buffer.
    local implicit = scope.parse({}, { bufnr = buf, has_range = true, line1 = 2, line2 = 3 })
    H.eq(implicit.kind, "selection", "a range with no scope word means the selection")
    H.eq(implicit.range.s, 2, "with the range it was given")

    -- Labels ----------------------------------------------------------------------
    H.eq(scope.label({ kind = "buffer" }), "buffer", "a plain kind is its own label")
    H.contains(
      scope.label({ kind = "path", path = "/tmp/x.md" }),
      "/tmp/x.md",
      "a path label names it"
    )
    H.contains(
      scope.label({ kind = "selection", range = { s = 2, e = 5 } }),
      "2-5",
      "a ranged label names the range"
    )
  end)
end
