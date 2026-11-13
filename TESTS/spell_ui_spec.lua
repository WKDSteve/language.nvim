-- TESTS/spell_ui_spec.lua — language.spell.ui.list + language.spell.ui.highlights.
--
-- Neither requires ui.kit (unlike panel.lua/item_menu.lua, which do at module
-- load and are deliberately left untested — see TESTS/README.md): list.lua
-- publishes into vim.diagnostic and lib.nvim.ui.list's quickfix helper,
-- highlights.lua sets buffer extmarks directly. use_trouble is left false
-- throughout so quickfix (always present) is exercised rather than the
-- optional trouble.nvim.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked(function()
    local list = require("language.spell.ui.list")
    local highlights = require("language.spell.ui.highlights")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one two three" })

    ---@type LanguageSpellIssue
    local issue1 =
      { bufnr = buf, path = "x", lnum = 1, col = 1, end_col = 4, word = "one", kind = "spell" }
    ---@type LanguageSpellIssue
    local issue2 =
      { bufnr = buf, path = "x", lnum = 1, col = 5, end_col = 8, word = "two", kind = "grammar" }

    -- publish / clear -----------------------------------------------------------
    local touched = list.publish({ issue1, issue2 }, "language.spell", nil, nil)
    H.ok(touched[buf], "publish reports the buffer it touched")
    local diags = vim.diagnostic.get(buf, { namespace = list.ns })
    H.eq(#diags, 2, "both issues became diagnostics")
    H.eq(diags[1].source, "language.spell", "tagged with the given source")

    list.clear({ [buf] = true })
    H.eq(#vim.diagnostic.get(buf, { namespace = list.ns }), 0, "clear() drops the diagnostics")

    -- The `max` cap limits diagnostics per buffer, without dropping the full
    -- list handed to the quickfix/panel layer.
    local many = {}
    for i = 1, 5 do
      many[i] = {
        bufnr = buf,
        path = "x",
        lnum = 1,
        col = i,
        end_col = i + 1,
        word = "w" .. i,
        kind = "spell",
      }
    end
    list.publish(many, "language.spell", 2, nil)
    H.eq(
      #vim.diagnostic.get(buf, { namespace = list.ns }),
      2,
      "at most `max` diagnostics per buffer"
    )
    list.clear()

    -- open() / refresh() / close() with the quickfix backend (use_trouble=false)
    list.open(
      { issue1, issue2 },
      { use_trouble = false, source = "language.spell", title = "Spell" }
    )
    local qf = vim.fn.getqflist()
    H.eq(#qf, 2, "open() populates the quickfix list")
    H.contains(qf[1].text, "one", "with the issue's word in the text")

    list.refresh({ issue1 }, { use_trouble = false, source = "language.spell", title = "Spell" })
    H.eq(#vim.fn.getqflist(), 1, "refresh() replaces the quickfix contents (action = r)")

    list.close(false)

    -- highlights: no-op unless enabled -----------------------------------------
    local none = highlights.publish({ issue1, issue2 }, nil)
    H.eq(vim.tbl_count(none), 0, "publish() is a no-op without cfg.enable")
    H.eq(#vim.api.nvim_buf_get_extmarks(buf, highlights.ns, 0, -1, {}), 0, "no extmarks were set")

    local hit = highlights.publish({ issue1, issue2 }, { enable = true, style = "underline" })
    H.ok(hit[buf], "publish() reports the touched buffer once enabled")
    local marks = vim.api.nvim_buf_get_extmarks(buf, highlights.ns, 0, -1, {})
    H.eq(#marks, 2, "one extmark per issue")

    highlights.clear({ [buf] = true })
    H.eq(
      #vim.api.nvim_buf_get_extmarks(buf, highlights.ns, 0, -1, {}),
      0,
      "clear() drops the buffer's extmarks"
    )

    -- A zero-width issue (end_col <= col) is skipped rather than crashing on an
    -- invalid extmark range.
    local zero_width =
      { bufnr = buf, path = "x", lnum = 1, col = 3, end_col = 3, word = "z", kind = "spell" }
    highlights.publish({ zero_width }, { enable = true, style = "underline" })
    H.eq(
      #vim.api.nvim_buf_get_extmarks(buf, highlights.ns, 0, -1, {}),
      0,
      "a zero-width span sets no extmark"
    )
    highlights.clear()

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end
