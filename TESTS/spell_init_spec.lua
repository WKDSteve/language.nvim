-- TESTS/spell_init_spec.lua — language.spell: the domain entry point (session
-- toggling, scope routing, cleanup). `spell.ui.view = "quickfix"` throughout,
-- so this exercises `language.spell.ui.list` rather than the interactive
-- panel (`spell/ui/panel.lua` requires `ui.kit` — see TESTS/README.md).
-- `language.spell.ui.panel` is still stubbed, because `M.clear()` calls
-- `panel.clear()` unconditionally regardless of the configured view.
--
-- Diagnostics (`vim.diagnostic.get(buf, {namespace = list.ns})`), not
-- `vim.fn.getqflist()`, are used to observe "is a session currently active":
-- `list.close()`'s quickfix branch is a plain `:cclose`, which closes the
-- window but does not clear the list's contents — so the quickfix list is
-- stale the instant a session toggles off, and only trustworthy right after
-- a fresh `list.open()`/`refresh()` call actually repopulated it.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked({ options = { "spell", "spelllang" } }, function()
    local config = require("language.config")
    local list = require("language.spell.ui.list")

    package.loaded["language.spell.ui.panel"] = {
      open = function() end,
      clear = function() end,
    }
    package.loaded["language.spell"] = nil
    local spell = require("language.spell")

    local BAD = "zzqqxxspellinittest"

    config.setup({
      spell = {
        ui = { view = "quickfix" },
        default_scope = "buffer",
        providers = { buffer = {}, cwd = {} },
        word_split = { enable = false },
        regions = { treesitter_spell = false },
        skip_readonly = true,
        keymaps = {},
      },
    })

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".md")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD })
    vim.api.nvim_set_current_buf(buf)

    ---@return integer
    local function diag_count()
      return #vim.diagnostic.get(buf, { namespace = list.ns })
    end

    -- run(): opens a session, publishes diagnostics + the quickfix list -------
    spell.run(nil, { kind = "buffer", bufnr = buf })
    H.eq(diag_count(), 1, "one spelling issue is published as a diagnostic")
    H.eq(#vim.fn.getqflist(), 1, "and the quickfix list is populated to match")
    H.contains(vim.fn.getqflist()[1].text, BAD, "with the flagged word")

    -- run() again on the same buffer toggles the session off -------------------
    spell.run(nil, { kind = "buffer", bufnr = buf })
    H.eq(diag_count(), 0, "a second run() on the same buffer closes the session")

    -- run() with a language temporarily changes 'spelllang' for the session ---
    local prev_spelllang = vim.bo[buf].spelllang
    -- Hermetic German dictionary: a tiny one is compiled with :mkspell into a
    -- fixture 'runtimepath' entry, so the spec needs neither a file installed in
    -- the real stdpath('data') nor the runtime's download prompt (network). Without
    -- any 'de' dictionary no word is ever flagged and the session never opens.
    local de_dir, de_cleanup = H.fixture("spell-init-de")
    vim.fn.mkdir(de_dir .. "/spell", "p")
    vim.fn.writefile({ "SET UTF-8" }, de_dir .. "/spell/de.aff")
    vim.fn.writefile({ "1", "hallo" }, de_dir .. "/spell/de.dic")
    local de_base = vim.fn.fnameescape(de_dir .. "/spell/de")
    vim.cmd(("silent mkspell! %s %s"):format(de_base, de_base))
    H.eq(
      vim.fn.filereadable(de_dir .. "/spell/de.utf-8.spl"),
      1,
      "the fixture dictionary was compiled"
    )
    local prev_rtp = vim.o.runtimepath
    vim.opt.runtimepath:prepend(de_dir)
    local buf_win = vim.fn.bufwinid(buf)
    vim.api.nvim_set_option_value("spell", false, { scope = "local", win = buf_win })
    local global_spell = vim.api.nvim_get_option_value("spell", { scope = "global" })
    local global_spelllang = vim.api.nvim_get_option_value("spelllang", { scope = "global" })
    spell.run("de", { kind = "buffer", bufnr = buf })
    H.eq(vim.bo[buf].spelllang, "de", "the session applies the requested language")
    H.ok(
      vim.api.nvim_get_current_win() ~= buf_win,
      "precondition: list.open() left the quickfix window current"
    )
    H.eq(vim.wo[buf_win].spell, true, "'spell' is switched on in the buffer's own window")

    -- clear() restores on the checked buffer and its window, even though the
    -- quickfix window is current: options must not be set or restored there.
    spell.clear()
    H.eq(vim.bo[buf].spelllang, prev_spelllang, "clear() restores the buffer's previous language")
    H.eq(vim.wo[buf_win].spell, false, "and the window's previous 'spell'")
    H.eq(
      vim.api.nvim_get_option_value("spell", { scope = "global" }),
      global_spell,
      "the global 'spell' is never touched by run/clear"
    )
    H.eq(
      vim.api.nvim_get_option_value("spelllang", { scope = "global" }),
      global_spelllang,
      "nor the global 'spelllang'"
    )
    H.eq(diag_count(), 0, "the diagnostics are cleared")

    -- Leave the buffer in a known-good state for the rest of this spec.
    vim.bo[buf].spelllang = prev_spelllang
    vim.o.runtimepath = prev_rtp
    de_cleanup()

    -- No issues: informs and does not open a session ---------------------------
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "clean text" })
    spell.run(nil, { kind = "buffer", bufnr = buf })
    H.eq(diag_count(), 0, "clean text: nothing is published")

    -- The shared scope word 'cword' is a :Translate scope, and is refused here -
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD })
    spell.run(nil, "cword")
    H.eq(diag_count(), 0, "cword is rejected outright, never scanned as a buffer")

    -- refresh(): re-scans an active session and updates the diagnostics -------
    spell.run(nil, { kind = "buffer", bufnr = buf })
    H.eq(diag_count(), 1, "the session is open again")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "clean now" })
    spell.refresh(buf)
    H.eq(diag_count(), 0, "refresh() sees the edit, finds nothing left, and auto-closes")

    -- refresh() on a buffer with no active session is a safe no-op ------------
    local other = vim.api.nvim_create_buf(false, true)
    local ok_refresh = pcall(spell.refresh, other)
    H.ok(ok_refresh, "refresh() on a buffer with no session does not error")
    vim.api.nvim_buf_delete(other, { force = true })

    -- run(): cwd/path scopes are a one-shot overview, no session to toggle ----
    local dir, cleanup = H.fixture("spell-init-cwd")
    vim.fn.writefile({ BAD }, dir .. "/note.md")
    spell.run(nil, { kind = "path", path = dir })
    vim.wait(2000, function()
      return #vim.fn.getqflist() > 0
    end)
    H.eq(#vim.fn.getqflist(), 1, "the async path scan populates the quickfix list too")
    cleanup()

    -- on_buf_delete(): drops session state and the native cache --------------
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD })
    spell.run(nil, { kind = "buffer", bufnr = buf })
    local cache = require("language.spell.core.cache")
    -- cache.get() needs the same cfg used at scan time (PERF-46: the config
    -- knobs that affect the scan are part of the cache key).
    local spell_cfg = require("language.config").get().spell
    H.ok(cache.get(buf, spell_cfg) ~= nil, "the native cache is populated for the open session")
    spell.on_buf_delete(buf)
    H.eq(cache.get(buf, spell_cfg), nil, "on_buf_delete() invalidates the cache")
    local ok_clear = pcall(spell.clear)
    H.ok(ok_clear, "clear() after on_buf_delete() does not error")

    vim.api.nvim_buf_delete(buf, { force = true })
    package.loaded["language.spell.ui.panel"] = nil
    package.loaded["language.spell"] = nil
    config.setup({})
  end)
end
