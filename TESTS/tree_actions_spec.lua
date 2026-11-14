-- TESTS/tree_actions_spec.lua — language.integrations.tree: the two actions
-- `language.check` and `language.translate` at lib.nvim.tree.registry, which
-- the own tree of filetree.nvim reads. Checked here are the entries and what
-- their `run` does with a node; that a tree offers a registered action on a
-- key and in its menu is filetree.nvim's own spec.
--
-- The facade (`require("language").spellcheck` / `.translate`) is the real
-- one; replaced are the two domain entry points behind it and the language
-- chooser of ui.kit, so nothing scans, translates or opens a window.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked(function()
    local registry = require("lib.nvim.tree.registry")
    local language = require("language")
    local tree = require("language.integrations.tree")
    local spell = require("language.spell")
    local translate = require("language.translate")
    local kit = require("ui.kit")

    ---@param name string
    ---@return table|nil
    local function entry(name)
      return registry.get("action", name)
    end

    -- what the two domains would be run with
    local checks, translations = {}, {}
    local real_spell_run, real_translate_run = spell.run, translate.run
    ---@diagnostic disable-next-line: duplicate-set-field
    spell.run = function(lang, scope)
      checks[#checks + 1] = { lang = lang, scope = scope }
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    translate.run = function(lang, opts)
      translations[#translations + 1] = { lang = lang, opts = opts }
    end

    -- the language chooser, answered from a queue; every question is recorded
    local answers, questions = {}, {}
    local real_select = kit.select
    ---@diagnostic disable-next-line: duplicate-set-field
    kit.select = function(o)
      questions[#questions + 1] = { title = o.title, items = o.items }
      o.on_select(table.remove(answers, 1))
    end

    -- every message
    local notes = {}
    local real_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      notes[#notes + 1] = { tostring(msg), level }
    end

    local function reset()
      checks, translations, answers, questions, notes = {}, {}, {}, {}, {}
    end

    -- which_key = false: see language_init_spec (the label queue of lib.nvim is module state).
    local base =
      { deps_popup = false, hover = false, commands = false, which_key = { enable = false } }
    ---@param extra? table
    local function setup(extra)
      language.setup(vim.tbl_deep_extend("force", {}, base, extra or {}))
    end

    local ok, err = pcall(function()
      -- ── setup registers them ───────────────────────────────────────────────
      setup()
      local check, tr = entry(tree.CHECK), entry(tree.TRANSLATE)
      H.ok(check, "setup registers language.check at the tree registry")
      H.ok(tr, "... and language.translate")
      ---@cast check table
      ---@cast tr table
      H.ok(vim.deep_equal(check.needs, { "path" }), "check applies to a node with a path")
      H.ok(vim.deep_equal(tr.needs, { "path" }), "translate applies to a node with a path")
      H.falsy(check.mutates, "a check changes no file")
      H.eq(tr.mutates, true, "a translation writes files and says so")
      H.eq(check.key, nil, "without a configured key check has none")
      H.eq(tr.key, nil, "... and translate has none")
      H.ok(type(check.desc) == "string" and check.desc ~= "", "check has a line for the menu")
      H.ok(type(tr.desc) == "string" and tr.desc ~= "", "translate has a line for the menu")

      -- ── language.check ─────────────────────────────────────────────────────
      -- a name with a blank and a `$`: the path goes through as it is, not through the
      -- `path=<p>` token of the command line (which splits on blanks and expands variables)
      local folder = "/some where/$docs"
      reset()
      check.run({ { path = folder, kind = "dir" } }, {})
      H.eq(#checks, 1, "check runs the spell check once")
      H.eq(checks[1].lang, nil, "... in the language of the editor")
      H.ok(
        vim.deep_equal(checks[1].scope, { kind = "path", path = folder }),
        "... with the node as a path scope: " .. vim.inspect(checks[1].scope)
      )
      H.eq(#questions, 0, "... and asks nothing")

      reset()
      check.run({ { path = folder .. "/a.md", kind = "file" } }, {})
      H.eq(checks[1].scope.path, folder .. "/a.md", "a file node is checked as that file")

      reset()
      check.run({ { id = "heading", kind = "group" } }, {})
      check.run({}, {})
      check.run(nil, {})
      H.eq(#checks, 0, "a node without a path, or none, checks nothing")

      reset()
      check.run({ { path = folder .. "/one.md" }, { path = folder .. "/two.md" } }, {})
      H.eq(#checks, 1, "with two nodes marked check runs once")
      H.eq(checks[1].scope.path, folder .. "/one.md", "... on the first")
      H.eq(#notes, 1, "... and says so")
      H.eq(notes[1][2], vim.log.levels.WARN, "... at warning level")
      H.contains(notes[1][1], "2 nodes", "... with the number of nodes")
      H.contains(notes[1][1], "one.md", "... naming the one it checks")

      -- ── language.translate: the language is asked for ──────────────────────
      reset()
      answers = { "DE" }
      tr.run({ { path = folder, kind = "dir" } }, {})
      H.eq(#questions, 1, "without translate.default_target translate asks for the language")
      H.contains(questions[1].title, "$docs", "... naming the node")
      H.ok(
        vim.deep_equal(questions[1].items, require("language.config").get().translate.default_langs),
        "... offering translate.default_langs"
      )
      H.eq(#translations, 1, "... and runs the translation once")
      H.eq(translations[1].lang, "DE", "... into the chosen language")
      H.ok(
        vim.deep_equal(translations[1].opts, { scope = { kind = "path", path = folder } }),
        "... with the node as a path scope: " .. vim.inspect(translations[1].opts)
      )

      reset()
      tr.run({ { path = folder, kind = "dir" } }, {})
      H.eq(#questions, 1, "a dismissed question was asked")
      H.eq(#translations, 0, "... and translates nothing")

      reset()
      tr.run({ { id = "heading", kind = "group" } }, {})
      tr.run({}, {})
      H.eq(#questions + #translations, 0, "a node without a path, or none, asks nothing")

      reset()
      answers = { "FR" }
      tr.run({ { path = folder .. "/one.md" }, { path = folder .. "/two.md" } }, {})
      H.eq(#translations, 1, "with two nodes marked translate runs once")
      H.eq(translations[1].opts.scope.path, folder .. "/one.md", "... on the first")
      H.ok(
        #notes == 1 and notes[1][2] == vim.log.levels.WARN and notes[1][1]:find("one.md", 1, true),
        "... and says which one, at warning level"
      )

      -- ── language.translate: translate.default_target answers the question ──
      setup({ translate = { default_target = "JA" } })
      tr = entry(tree.TRANSLATE)
      ---@cast tr table
      reset()
      tr.run({ { path = folder .. "/a.md", kind = "file" } }, {})
      H.eq(#questions, 0, "with translate.default_target nothing is asked")
      H.eq(#translations, 1, "... and the translation runs")
      H.eq(translations[1].lang, "JA", "... into that language")
      H.eq(translations[1].opts.scope.path, folder .. "/a.md", "... on the node")

      -- ── the option ─────────────────────────────────────────────────────────
      setup({ tree = { key = { check = "<leader>sc", translate = { "<leader>st", "gT" } } } })
      H.eq(entry(tree.CHECK).key, "<leader>sc", "tree.key.check puts check on that key")
      H.ok(
        vim.deep_equal(entry(tree.TRANSLATE).key, { "<leader>st", "gT" }),
        "tree.key.translate may be several keys"
      )
      local names = {}
      for _, e in ipairs(registry.list("action")) do
        if e.name == tree.CHECK or e.name == tree.TRANSLATE then
          names[#names + 1] = e.name
        end
      end
      H.eq(#names, 2, "a second setup() replaces the two entries, it does not add two")

      setup({ tree = { key = { check = "<leader>sc" } } })
      H.eq(entry(tree.CHECK).key, "<leader>sc", "one key alone: check has it")
      H.eq(entry(tree.TRANSLATE).key, nil, "... and translate has none")

      setup({ tree = { key = { check = false } } })
      H.eq(entry(tree.CHECK).key, nil, "a key of false is no key")

      setup({ tree = {} })
      H.ok(entry(tree.CHECK) and entry(tree.TRANSLATE), "an empty table offers both, without keys")

      H.falsy(pcall(setup, { tree = "yes" }), "tree = <string> is refused by setup()")
      H.falsy(pcall(setup, { tree = { key = "<leader>sc" } }), "tree.key must name the actions")
      H.falsy(pcall(setup, { tree = { key = { check = 7 } } }), "a key that is none is refused")

      setup({ tree = false })
      H.eq(entry(tree.CHECK), nil, "tree = false takes check out")
      H.eq(entry(tree.TRANSLATE), nil, "... and translate")

      setup()
      H.ok(entry(tree.CHECK) and entry(tree.TRANSLATE), "the default offers them again")
      tree.unregister()
      H.eq(entry(tree.CHECK), nil, "unregister removes check")
      H.eq(entry(tree.TRANSLATE), nil, "... and translate")
      tree.unregister()
      H.eq(entry(tree.TRANSLATE), nil, "a second unregister is harmless")

      -- somebody else's entry under the same name is not removed by ours
      H.eq(tree.register(), true, "register() answers true with a registry")
      local remove_other = registry.action({ name = tree.CHECK, run = function() end })
      tree.unregister()
      H.ok(entry(tree.CHECK), "an entry that replaced ours stays when we unregister")
      remove_other()
    end)

    tree.unregister()
    spell.run, translate.run = real_spell_run, real_translate_run
    kit.select = real_select
    vim.notify = real_notify
    require("language.config").setup({})
    if not ok then
      error(err, 0)
    end
  end)
end
