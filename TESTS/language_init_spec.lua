-- TESTS/language_init_spec.lua — language.init: the setup() entry point that
-- wires config, commands, keymaps, autocmds and the optional hover.nvim
-- integration together. This drives the real setup() end to end (no
-- stubbing) and asserts on the observable, checkable side effects: whether
-- the commands exist, and that setup() never errors regardless of the
-- gating flags.

return function(H)
  -- Every spec file shares one editor: put back what this one creates, also on failure (see H.tracked).
  H.tracked(function()
    local language = require("language")
    local which_key = require("lib.nvim.bindings.keymap.which_key")
    local queued_before = which_key.pending_count()
    ---@return integer
    local function watchers()
      local ok, list = pcall(vim.api.nvim_get_autocmds, { group = "lib.nvim.which_key.pending" })
      return ok and #list or 0
    end
    local watchers_before = watchers()

    -- which_key = false throughout: with no which-key installed, setup() would
    -- queue the label groups in lib.nvim and arm a module-local watcher that
    -- H.tracked can only half undo (it deletes the autocmd, the module keeps
    -- `watching = true` and the queue for the rest of the run).
    local base = { deps_popup = false, hover = false, which_key = { enable = false } }
    ---@param extra table
    ---@return table
    local function opts(extra)
      return vim.tbl_extend("force", base, extra)
    end

    -- A clean slate regardless of what other specs registered first: this spec
    -- asserts on presence/absence of the three commands, and with isolated = "none"
    -- all spec files share one editor, so it cannot rely on the order the runner
    -- loads them in to guarantee none of them exist yet.
    for _, name in ipairs({ "Spellcheck", "Translate", "TranslateReplace", "TranslateOffice" }) do
      pcall(vim.api.nvim_del_user_command, name)
    end

    -- commands = false: no :Spellcheck/:Translate/:TranslateReplace ------------
    local ok1 = pcall(language.setup, opts({ commands = false }))
    H.ok(ok1, "setup() with commands = false does not error")
    H.eq(vim.fn.exists(":Spellcheck"), 0, "commands = false: :Spellcheck is not registered")
    H.eq(vim.fn.exists(":Translate"), 0, "nor :Translate")

    -- commands = true (default): all three are registered ---------------------
    local ok2 = pcall(language.setup, opts({ commands = true }))
    H.ok(ok2, "setup() with commands = true does not error")
    H.eq(vim.fn.exists(":Spellcheck"), 2, ":Spellcheck is registered (2 = a user command)")
    H.eq(vim.fn.exists(":Translate"), 2, ":Translate is registered")
    H.eq(vim.fn.exists(":TranslateReplace"), 2, ":TranslateReplace is registered")

    -- setup() is safe to call again (idempotent-ish, per its own docstring) ---
    local ok3 = pcall(language.setup, opts({ commands = true }))
    H.ok(ok3, "a second setup() call does not error")

    -- The Lua facade delegates into the same submodules the commands do -------
    H.eq(type(language.spellcheck), "function", "M.spellcheck exists")
    H.eq(type(language.translate), "function", "M.translate exists")
    H.eq(type(language.translate_replace), "function", "M.translate_replace exists")
    H.eq(type(language.synonyms), "function", "M.synonyms exists")
    H.eq(type(language.open_panel), "function", "M.open_panel exists")

    -- M.health is a lazy façade over language.health, not the module itself --
    H.eq(type(language.health.check), "function", "M.health.check resolves lazily")

    -- programming_dict / extra_wordlists gating: must not error either way ----
    local ok4 = pcall(
      language.setup,
      opts({
        commands = true,
        spell = { programming_dict = true, extra_wordlists = { t = { "abc" } } },
      })
    )
    H.ok(ok4, "setup() with programming_dict/extra_wordlists enabled does not error")

    -- which_key = false really keeps lib.nvim's which-key queue untouched ---
    H.eq(which_key.pending_count(), queued_before, "which_key = false queues no label groups")
    H.eq(watchers(), watchers_before, "which_key = false arms no which-key watcher")

    require("language.config").setup({})
  end)
end
