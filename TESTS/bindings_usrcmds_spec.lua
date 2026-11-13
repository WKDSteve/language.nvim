-- TESTS/bindings_usrcmds_spec.lua — language.bindings.usrcmds: the real
-- :Spellcheck/:Translate/:TranslateReplace dispatch, driven through the real
-- Ex commands (composer registers real `nvim_create_user_command`s), with
-- `language.spell`/`language.translate`/`language.translate.window` stubbed
-- so this asserts on scope/flag parsing rather than on a real scan/network
-- call. Same "drive the real command" approach debugging.nvim's
-- bindings_spec.lua uses for `:Debug`.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked(function()
    ---@type table[]
    local spell_calls, translate_calls, window_calls

    local function stub_domains()
      spell_calls, translate_calls, window_calls = {}, {}, {}
      package.loaded["language.spell"] = {
        run = function(lang, scope)
          spell_calls[#spell_calls + 1] = { fn = "run", lang = lang, scope = scope }
        end,
        clear = function()
          spell_calls[#spell_calls + 1] = { fn = "clear" }
        end,
        refresh = function()
          spell_calls[#spell_calls + 1] = { fn = "refresh" }
        end,
      }
      package.loaded["language.translate"] = {
        run = function(lang, opts)
          translate_calls[#translate_calls + 1] = { fn = "run", lang = lang, opts = opts }
        end,
        run_files = function(lang, opts)
          translate_calls[#translate_calls + 1] = { fn = "run_files", lang = lang, opts = opts }
        end,
      }
      package.loaded["language.translate.window"] = {
        open = function(opts)
          window_calls[#window_calls + 1] = opts
        end,
      }
    end

    stub_domains()
    package.loaded["language.bindings.usrcmds"] = nil
    local usrcmds = require("language.bindings.usrcmds")
    usrcmds.setup()

    -- :Spellcheck -----------------------------------------------------------
    vim.cmd("Spellcheck")
    H.eq(#spell_calls, 1, ":Spellcheck with no args calls spell.run once")
    H.eq(spell_calls[1].fn, "run", "run, not clear/refresh")
    H.eq(spell_calls[1].scope.kind, "buffer", "defaulting to the buffer scope")

    vim.cmd("Spellcheck de buffer")
    H.eq(spell_calls[2].lang, "de", "the language token is passed through")
    H.eq(spell_calls[2].scope.kind, "buffer", "and the scope word is parsed")

    vim.cmd("Spellcheck clear")
    H.eq(spell_calls[3].fn, "clear", "'clear' is a session-control verb, not a scope/lang")

    vim.cmd("Spellcheck refresh")
    H.eq(spell_calls[4].fn, "refresh", "so is 'refresh'")

    -- :Translate ------------------------------------------------------------
    vim.cmd("Translate FR")
    H.eq(#translate_calls, 1, ":Translate FR calls translate.run once")
    H.eq(translate_calls[1].lang, "FR", "with the language")
    H.eq(translate_calls[1].opts.scope.kind, "buffer", "default scope is buffer")
    H.eq(translate_calls[1].opts.nocode, false, "nocode defaults to false")
    H.eq(
      translate_calls[1].opts.output,
      nil,
      "no --output=: nil (translate.lua applies its own default)"
    )

    vim.cmd("Translate FR --nocode")
    H.eq(translate_calls[2].opts.nocode, true, "--nocode sets opts.nocode")

    vim.cmd("Translate FR -nocode")
    H.eq(translate_calls[3].opts.nocode, true, "the single-dash spelling works too")

    vim.cmd("Translate FR --output=buffer")
    H.eq(translate_calls[4].opts.output, "buffer", "--output=<mode> is parsed")

    vim.cmd("Translate DE cword")
    H.eq(translate_calls[5].lang, "DE", "cword: the language is still the leftover token")
    H.eq(
      translate_calls[5].opts.scope.kind,
      "cword",
      "and cword is recognised as a scope, not a 2nd lang"
    )

    vim.cmd("Translate FR selection")
    H.eq(translate_calls[6].opts.scope.kind, "selection", "an explicit selection scope")

    -- cwd/path → routed to run_files, never to translate.run --------------
    local before_run_files = #translate_calls
    vim.cmd("Translate FR cwd")
    H.eq(translate_calls[before_run_files + 1].fn, "run_files", "cwd is routed to run_files")
    H.eq(translate_calls[before_run_files + 1].lang, "FR", "with the language")

    vim.cmd("Translate FR --files=replace cwd")
    H.eq(
      translate_calls[#translate_calls].opts.mode,
      "replace",
      "--files=<mode> reaches run_files as opts.mode"
    )

    -- `path=<dir>` opens the multi-file picker, `path=<file>` translates that one file through
    -- the same run_files path. `--nocode` is not forwarded to run_files either.
    local scratch_dir = (vim.fn.tempname() .. "-usrcmds"):gsub("\\", "/")
    vim.fn.mkdir(scratch_dir, "p")
    local scratch_file = scratch_dir .. "/note.md"
    vim.fn.writefile({ "hello" }, scratch_file)

    vim.cmd("Translate FR --nocode path=" .. scratch_dir)
    local dir_call = translate_calls[#translate_calls]
    H.eq(dir_call.fn, "run_files", "path=<dir> is routed to run_files")
    H.eq(vim.fs.normalize(dir_call.opts.dir), vim.fs.normalize(scratch_dir), "with that directory")
    H.eq(dir_call.opts.nocode, nil, "--nocode is not forwarded to the multi-file translation")

    vim.cmd("Translate FR path=" .. scratch_file)
    local file_call = translate_calls[#translate_calls]
    H.eq(file_call.fn, "run_files", "path=<file> is routed to run_files")
    H.eq(
      vim.fs.normalize(file_call.opts.file),
      vim.fs.normalize(scratch_file),
      "as that one file (no picker)"
    )
    H.eq(file_call.opts.dir, nil, "not as a directory")

    vim.cmd("TranslateReplace FR path=" .. scratch_file)
    H.eq(translate_calls[#translate_calls].opts.mode, "replace", "TranslateReplace forces replace")

    -- A path that does not exist is reported (notify.error re-raises through
    -- vim.cmd, hence the pcall) and reaches neither run nor run_files.
    local before_missing = #translate_calls
    local ok_missing, missing_err =
      pcall(vim.cmd, "Translate FR path=" .. scratch_dir .. "/nope.md")
    H.eq(#translate_calls, before_missing, "a missing path reaches neither run nor run_files")
    H.ok(
      not ok_missing and tostring(missing_err):find("no such file or directory", 1, true) ~= nil,
      "and is reported as missing"
    )

    vim.fn.delete(scratch_dir, "rf")

    vim.cmd("Translate FR visible")
    H.eq(
      translate_calls[#translate_calls].opts.scope.kind,
      "visible",
      "visible is a scope word of :Translate too"
    )

    -- bang → the interactive window, never translate.run ----------------------
    local before_translate_calls = #translate_calls
    vim.cmd("Translate! FR")
    H.eq(#translate_calls, before_translate_calls, "a bang call never reaches translate.run")
    H.eq(#window_calls, 1, "it opens the interactive window instead")
    H.eq(window_calls[1].target, "FR", "prefilled with the given language")

    -- :TranslateReplace — always replace, regardless of flags ------------------
    vim.cmd("TranslateReplace FR")
    local tr = translate_calls[#translate_calls]
    H.eq(tr.fn, "run", "TranslateReplace calls translate.run")
    H.eq(tr.opts.output, "replace", "forced to replace")

    vim.cmd("TranslateReplace FR --nocode")
    H.eq(translate_calls[#translate_calls].opts.nocode, true, "and still honours --nocode")

    vim.cmd("TranslateReplace FR cwd")
    H.eq(translate_calls[#translate_calls].fn, "run_files", "cwd routes through run_files too")
    H.eq(
      translate_calls[#translate_calls].opts.mode,
      "replace",
      "forced to replace mode there as well"
    )

    -- A typo'd scope word (ERR-10) must not silently fall through to the
    -- default whole-buffer scope: it is neither the language nor a
    -- recognized scope word, so it is a leftover 2nd token and is rejected.
    -- `vim.cmd(string)` runs through `nvim_exec2`, which re-raises a
    -- notify.error() issued inside the handler as a Lua error here (an
    -- interactive `:TranslateReplace ...` would not do this -- there is no
    -- Lua caller for it to unwind into) -- pcall so the assertion below still
    -- runs.
    local before_typo = #translate_calls
    pcall(vim.cmd, "TranslateReplace DE selction")
    H.eq(#translate_calls, before_typo, "an unrecognized 2nd token aborts before run/run_files")

    -- :TranslateOffice <file> <lang> --------------------------------------------
    local office_calls = {}
    package.loaded["language.translate.office"] = {
      translate_file = function(file, lang, _, cb)
        office_calls[#office_calls + 1] = { file = file, lang = lang }
        cb(true, file .. ".out")
      end,
    }
    vim.cmd("TranslateOffice deck.pptx de")
    H.eq(#office_calls, 1, ":TranslateOffice reaches translate_file once")
    H.eq(office_calls[1].file, "deck.pptx", "with the file")
    H.eq(office_calls[1].lang, "de", "and the language")
    vim.cmd('TranslateOffice "my deck.pptx" fr')
    H.eq(office_calls[2].file, "my deck.pptx", "a quoted file name keeps its blank")
    H.eq(office_calls[2].lang, "fr", "and the language after it is still the language")
    package.loaded["language.translate.office"] = nil

    package.loaded["language.spell"] = nil
    package.loaded["language.translate"] = nil
    package.loaded["language.translate.window"] = nil
    package.loaded["language.bindings.usrcmds"] = nil
  end)
end
