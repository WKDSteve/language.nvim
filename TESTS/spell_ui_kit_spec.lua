-- TESTS/spell_ui_kit_spec.lua — language.spell.ui.item_menu and language.spell.ui.panel,
-- the two spell UI modules that require ui.kit at load. They run against the REAL ui.kit
-- (ui.nvim is a dependency of the suite, see .testing.lua); only the calls that would open a
-- window (kit.select, kit.menu, kit.chooser) and the mutating core actions are replaced by
-- recorders, so the spec checks what the modules build and call.

return function(H)
  H.tracked(function()
    local kit = require("ui.kit")
    local actions = require("language.spell.core.actions")
    local ignore = require("language.spell.core.ignore")
    local item_menu = require("language.spell.ui.item_menu")
    local panel = require("language.spell.ui.panel")

    -- Put every replaced field back, also when an assertion throws half-way.
    local restores = {}
    local function patch(tbl, key, value)
      restores[#restores + 1] = { tbl, key, tbl[key] }
      tbl[key] = value
    end
    local function restore_all()
      for i = #restores, 1, -1 do
        local r = restores[i]
        r[1][r[2]] = r[3]
      end
      restores = {}
    end

    local ok, err = pcall(function()
      -- A chosen suggestion replaces only the occurrence under the issue (not every one)
      require("language.config").setup({ spell = { dictionary = { replace_all = false } } })

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "teh quick brown fox" })

      ---@type LanguageSpellIssue
      local spell_issue = {
        bufnr = buf,
        path = "x.txt",
        lnum = 1,
        col = 1,
        end_col = 4,
        word = "teh",
        kind = "spell",
        suggestions = { "the", "ten" },
      }
      ---@type LanguageSpellIssue
      local grammar_issue = {
        bufnr = buf,
        path = "x.txt",
        lnum = 1,
        col = 5,
        end_col = 10,
        word = "quick",
        kind = "grammar",
        source = "harper",
        message = "Use a different word",
      }

      local function ids(items)
        local out = {}
        for _, it in ipairs(items) do
          out[#out + 1] = it.id
        end
        return table.concat(out, ",")
      end

      -- item_menu._items: which actions each kind of issue offers ---------------------
      H.eq(
        ids(item_menu._items(spell_issue, function() end)),
        "suggest,replace_all,add_dict,ignore_session,ignore_persistent,jump",
        "a spelling issue offers suggestion, replace-all, dictionary, both ignores and jump"
      )
      H.eq(
        ids(item_menu._items(grammar_issue, function() end)),
        "lsp_fix,ignore_session,ignore_persistent,jump",
        "a grammar issue (harper) is fixed through the LSP, not through suggestions"
      )

      -- The recorders -----------------------------------------------------------------
      local menus, selects = {}, {}
      patch(kit, "menu", function(opts)
        menus[#menus + 1] = opts
      end)
      patch(kit, "select", function(opts)
        selects[#selects + 1] = opts
        return nil
      end)

      -- item_menu.open: title and items -------------------------------------------------
      item_menu.open(spell_issue)
      H.eq(menus[1].title, "teh", "the menu of a spelling issue is titled with the word")
      H.eq(#menus[1].items, 6, "and carries the six actions")
      item_menu.open(grammar_issue)
      H.eq(menus[2].title, "Use a different word", "a grammar issue is titled with its message")

      -- Actions call the core and then on_done -------------------------------------------
      local done = 0
      local function on_done()
        done = done + 1
      end
      local function find(issue, id)
        for _, it in ipairs(item_menu._items(issue, on_done)) do
          if it.id == id then
            return it
          end
        end
      end

      local added
      patch(actions, "add_to_dict", function(word)
        added = word
        return true
      end)
      find(spell_issue, "add_dict").action()
      H.eq(added, "teh", "add_dict hands the word to actions.add_to_dict")
      H.eq(done, 1, "and re-opens the panel through on_done")

      local failing
      patch(actions, "add_to_dict", function(word)
        failing = word
        return false, "boom"
      end)
      find(spell_issue, "add_dict").action()
      H.eq(failing, "teh", "a failing add is attempted")
      H.eq(done, 1, "but does not call on_done")

      local session_word = "zzqqkitspec" .. tostring(vim.uv.hrtime())
      find({ word = session_word, kind = "spell", lnum = 1, col = 1 }, "ignore_session").action()
      H.ok(ignore.has(session_word), "ignore_session adds the word to the session set")
      H.eq(done, 2, "and calls on_done")

      local persisted
      patch(ignore, "add_persistent", function(word)
        persisted = word
        return true
      end)
      find(spell_issue, "ignore_persistent").action()
      H.eq(persisted, "teh", "ignore_persistent writes through ignore.add_persistent")
      H.eq(done, 3, "and calls on_done")

      -- suggest: the chosen suggestion replaces at the issue ------------------------------
      local replaced
      patch(actions, "replace_at", function(issue, word)
        replaced = { issue = issue, word = word }
        return true
      end)
      find(spell_issue, "suggest").action()
      local sel = selects[#selects]
      H.eq(
        table.concat(sel.items, ","),
        "the,ten",
        "the suggestion picker lists the issue's suggestions"
      )
      sel.on_select("ten")
      H.eq(replaced.word, "ten", "choosing a suggestion calls replace_at with it")
      H.eq(replaced.issue, spell_issue, "for this issue")
      H.eq(done, 4, "and calls on_done")

      sel.on_select("")
      H.eq(replaced.word, "ten", "an empty choice replaces nothing")
      H.eq(done, 4, "and calls nothing")

      -- replace_all goes through replace_all_in_buffer -------------------------------------
      local all_args
      patch(actions, "replace_all_in_buffer", function(b, from, to)
        all_args = { b, from, to }
        return true, 2
      end)
      find(spell_issue, "replace_all").action()
      selects[#selects].on_select("the")
      H.eq(
        table.concat({ all_args[1], all_args[2], all_args[3] }, ":"),
        buf .. ":teh:the",
        "replace_all swaps the word in the whole buffer"
      )
      H.eq(done, 5, "and calls on_done")

      -- no suggestions: nothing is opened --------------------------------------------------
      local before = #selects
      local bare = { bufnr = buf, word = "q", kind = "spell", lnum = 1, col = 1, suggestions = {} }
      find(bare, "suggest").action()
      H.eq(#selects, before, "an issue without suggestions opens no picker")

      -- jump_to moves the cursor -------------------------------------------------------------
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      item_menu.jump_to(grammar_issue)
      H.eq(
        table.concat(vim.api.nvim_win_get_cursor(0), ":"),
        "1:4",
        "jump_to puts the cursor on the issue"
      )

      -- panel._render --------------------------------------------------------------------------
      local surf_buf = vim.api.nvim_create_buf(false, true)
      selects = {}
      patch(kit, "select", function(opts)
        selects[#selects + 1] = opts
        return { bufnr = surf_buf }
      end)
      local current = 2
      local closed = 0
      patch(kit.chooser, "current_index", function()
        return current
      end)
      patch(kit.chooser, "close", function()
        closed = closed + 1
      end)

      -- A mutating key re-opens the panel through vim.schedule; record that instead of rescanning.
      local reopened = 0
      patch(panel, "open", function()
        reopened = reopened + 1
      end)

      local cfg = { max_highlights = 10 }
      local scope = { kind = "buffer", bufnr = buf }
      panel._render(scope, cfg, { spell_issue, grammar_issue })
      local s = selects[1]
      H.eq(#s.items, 2, "the panel lists one row per issue")
      H.contains(s.items[1], "teh", "the row names the word")
      H.contains(s.items[1], "[spell]", "and its kind")
      H.contains(s.items[2], "[grammar]", "the second row is the grammar issue")
      H.contains(s.title, "2 issue(s)", "the title counts the issues")

      -- The direct keys are set buffer-locally on the chooser buffer
      local function map_of(lhs)
        return vim.api.nvim_buf_call(surf_buf, function()
          return vim.fn.maparg(lhs, "n", false, true)
        end)
      end
      for _, lhs in ipairs({ "a", "i", "I", "L", "gd", "o", "?" }) do
        H.ok(map_of(lhs).callback ~= nil, "panel key `" .. lhs .. "` is mapped")
      end

      -- Selecting a row opens that issue's menu
      local opened
      patch(item_menu, "open", function(issue)
        opened = issue
      end)
      s.on_select(nil, 1)
      H.eq(opened, spell_issue, "selecting a row opens the action menu of that issue")

      local function press(lhs)
        map_of(lhs).callback()
      end

      -- `a` on a grammar issue (row 2) has no add_dict: reported, chooser still closed
      press("a")
      H.eq(closed, 1, "a direct key closes the chooser before it acts")

      -- `i` on the grammar issue ignores its word for the session
      local gw = "zzqqpanelkey" .. tostring(vim.uv.hrtime())
      grammar_issue.word = gw
      panel._render(scope, cfg, { spell_issue, grammar_issue })
      press("i")
      H.ok(ignore.has(gw), "`i` ignores the word under the cursor for this session")

      -- `a` on the spelling issue (row 1) adds it to the dictionary
      current = 1
      added = nil
      patch(actions, "add_to_dict", function(word)
        added = word
        return true
      end)
      press("a")
      H.eq(added, "teh", "`a` adds the word under the cursor to the dictionary")
      vim.wait(500, function()
        return reopened > 0
      end, 10)
      H.ok(reopened > 0, "and the panel is re-opened afterwards")

      -- Nothing under the cursor: the key is a no-op
      current = nil
      local c = closed
      press("i")
      H.eq(closed, c, "no current row: the key does nothing")

      -- No issues: nothing is opened
      local n = #selects
      panel._render(scope, cfg, {})
      H.eq(#selects, n, "an empty result opens no panel")

      -- on_cancel clears the published diagnostics
      local list = require("language.spell.ui.list")
      panel._render(scope, cfg, { spell_issue })
      H.ok(#vim.diagnostic.get(buf, { namespace = list.ns }) > 0, "the panel publishes diagnostics")
      selects[#selects].on_cancel()
      H.eq(#vim.diagnostic.get(buf, { namespace = list.ns }), 0, "cancelling clears them")
    end)

    restore_all()
    if not ok then
      error(err, 0)
    end
  end)
end
