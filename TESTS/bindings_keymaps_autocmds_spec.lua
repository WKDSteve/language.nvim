-- TESTS/bindings_keymaps_autocmds_spec.lua — language.bindings.keymaps and
-- language.bindings.autocmds: the real registration, driven through
-- `lib.nvim.bindings.keymap`/`lib.nvim.bindings.autocmd`'s own introspection
-- (`keymap.registered`, `autocmd.registered`) — the same technique
-- debugging.nvim's bindings_spec.lua uses.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked(function()
    local keymaps = require("language.bindings.keymaps")
    local autocmds = require("language.bindings.autocmds")
    local keymap = require("lib.nvim.bindings.keymap")
    local autocmd = require("lib.nvim.bindings.autocmd")

    -- keymaps.setup(): spell/translate/thesaurus surfaces --------------------
    local cfg = {
      spell = {
        keymaps = { panel = "<leader>Zss", fix = "<leader>Zz=", fix1 = "<leader>Zz1", next = "]Z" },
      },
      translate = { keymaps = { operator = false, visual = false, to = {} } },
      thesaurus = { keymap = "<leader>Zth" },
      which_key = { enable = true },
    }
    keymaps.setup(cfg, false) -- which_key = false: skip label_groups (which-key not installed here)

    local spell_bound = keymap.registered("language/spell")
    H.eq(
      #spell_bound,
      1,
      "only 'panel' is a global keymap action here (fix/fix1/next are session-local)"
    )
    H.eq(spell_bound[1].name, "panel", "the panel action")
    H.eq(spell_bound[1].lhs, "<leader>Zss", "bound at the configured lhs")
    H.ok(spell_bound[1].bound, "and really bound, not just declared")

    local translate_bound = keymap.registered("language/translate")
    local by_name = {}
    for _, e in ipairs(translate_bound) do
      by_name[e.name] = e
    end
    H.falsy(by_name.operator.bound, "operator = false: declared but not bound")
    H.falsy(by_name.visual.bound, "visual = false likewise")

    local thesaurus_bound = keymap.registered("language/thesaurus")
    H.eq(#thesaurus_bound, 1, "one thesaurus action")
    H.eq(thesaurus_bound[1].lhs, "<leader>Zth", "at the configured lhs")

    -- Per-language operator/visual keys (translate.keymaps.to) ------------------
    keymaps.setup(
      vim.tbl_deep_extend("force", cfg, {
        translate = { keymaps = { operator = false, visual = false, to = { FR = "<leader>ZtF" } } },
      }),
      false
    )
    local translate_bound2 = keymap.registered("language/translate")
    local to_fr
    for _, e in ipairs(translate_bound2) do
      if e.name == "to_FR" then
        to_fr = to_fr or {}
        to_fr[#to_fr + 1] = e
      end
    end
    H.ok(to_fr, "translate.keymaps.to.FR registers a 'to_FR' action")
    H.eq(#to_fr, 2, "with both its normal (operator) and visual binds")

    ---@param records table[]
    ---@return table<string, true>
    local function event_set(records)
      local set = {}
      for _, r in ipairs(records) do
        for _, e in ipairs(r.events or {}) do
          set[e] = true
        end
      end
      return set
    end

    -- autocmds.setup(): the BufDelete GC hook is always registered -------------
    autocmds.setup({ spell = {} })
    local events = event_set(autocmd.registered({ group = "language_nvim" }))
    H.ok(events.BufDelete, "the GC/live-detach hook is registered unconditionally")
    H.falsy(
      events.TextChanged,
      "live scanning's autocmds are NOT registered when spell.live is unset"
    )

    -- autocmds.setup(): live = true arms the debounced scan ---------------------
    autocmds.setup({ spell = { live = true, live_scope = "visible" } })
    local live_events = event_set(autocmd.registered({ group = "language_nvim" }))
    H.ok(live_events.TextChanged, "spell.live = true arms the debounced rescan")
    H.ok(live_events.WinScrolled, "and, with live_scope = 'visible', the scroll-follow rescan too")

    -- autocmds.setup(): the write guard really blocks :w on real spelling
    -- issues. A real `:write` is used rather than `nvim_exec_autocmds`: the
    -- latter swallows a callback error into an "Error in ... Autocommands"
    -- message instead of propagating it, which is exactly the abort mechanism
    -- the guard's own `error()` relies on, so only a real `:write` exercises it.
    local path = vim.fn.tempname() .. ".md"
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "zzqqxxguardtest" })
    vim.api.nvim_set_current_buf(buf)

    autocmds.setup({
      spell = { filetypes = { "markdown" }, guard = { block_write_on_error = true } },
    })
    local write_ok = pcall(vim.cmd, "write")
    H.falsy(write_ok, "a real spelling issue aborts :write via the guard")
    H.eq(vim.fn.filereadable(path), 0, "and the file was never actually written")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "clean text" })
    local write_ok2 = pcall(vim.cmd, "write")
    H.ok(write_ok2, "clean text: the guard lets the write proceed")
    H.eq(vim.fn.filereadable(path), 1, "and the file is really written")

    vim.api.nvim_buf_delete(buf, { force = true })
    pcall(os.remove, path)

    -- Re-running setup() with the guard off does not leave a stale guard
    -- autocmd behind (autocmd.group(name, true) clears the group first).
    autocmds.setup({
      spell = { filetypes = { "markdown" }, guard = { block_write_on_error = false } },
    })
    local off_events = event_set(autocmd.registered({ group = "language_nvim" }))
    H.falsy(off_events.BufWritePre, "turning the guard off again really removes its autocmd")

    -- keymaps = false: the master switch binds nothing --------------------------
    local config = require("language.config")
    config.setup({ keymaps = false })
    H.eq(config.get().keymaps.enable, false, "keymaps = false is normalized to { enable = false }")
    config.setup({ keymaps = true })
    H.eq(config.get().keymaps.enable, true, "keymaps = true keeps the switch on")

    config.setup({
      keymaps = false,
      spell = { keymaps = { panel = "<leader>Zoff" } },
      translate = { keymaps = { operator = "<leader>Zofo", visual = "<leader>Zofv" } },
      thesaurus = { keymap = "<leader>Zoft" },
    })
    keymaps.setup(config.get(), false)
    for _, lhs in ipairs({ "<leader>Zoff", "<leader>Zofo", "<leader>Zofv", "<leader>Zoft" }) do
      H.eq(
        vim.fn.maparg(lhs, "n") == "" and vim.fn.maparg(lhs, "x") == "",
        true,
        lhs .. " is not bound"
      )
    end

    config.setup({})
  end)
end
