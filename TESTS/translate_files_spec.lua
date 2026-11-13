-- TESTS/translate_files_spec.lua — language.translate.files: multi-file
-- translation. `M.gather` and `M.process` are explicitly "Public for testing"
-- in the source and are exercised directly against a real fixture directory
-- and a fake (injected) provider. `M.run`'s picker (`ui.kit`) and its
-- confirm() prompt are not reached: both early-return paths (no target, no
-- files under the directory) are tested instead — see TESTS/README.md for why
-- `ui.kit` itself is out of scope for this suite.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked(function()
    local files = require("language.translate.files")
    local config = require("language.config")

    local dir, cleanup = H.fixture("translate-files")
    vim.fn.mkdir(dir .. "/sub", "p")
    vim.fn.mkdir(dir .. "/node_modules", "p")
    vim.fn.writefile({ "hello" }, dir .. "/a.md")
    vim.fn.writefile({ "world" }, dir .. "/sub/b.md")
    vim.fn.writefile({ "ignored" }, dir .. "/node_modules/c.md")
    vim.fn.writefile({ "not a translatable extension" }, dir .. "/d.exe")

    local cfg = { files = { extensions = { "md" }, max_kb = 512 } }

    -- gather() ------------------------------------------------------------------
    local found = files.gather(dir, cfg)
    local rels = {}
    for _, f in ipairs(found) do
      rels[#rels + 1] = f.rel
    end
    table.sort(rels)
    H.eq(table.concat(rels, ","), "a.md,sub/b.md", "only .md files, node_modules skipped, sorted")

    H.eq(
      #files.gather(dir, { files = { extensions = { "txt" } } }),
      0,
      "no matching extension: none"
    )

    local tiny_cfg = { files = { extensions = { "md" }, max_kb = 0 } }
    H.eq(#files.gather(dir, tiny_cfg), 0, "a max_kb of 0 excludes every file, however small")

    -- gather(): a walk that fails partway (permissions, a vanishing entry, …)
    -- must not crash and must not silently look like "this directory has no
    -- matching files" with no trace (ERR-11) -- same failure already fixed in
    -- spell/providers/native.lua's gather_tree_files, same fix here. A
    -- warning is raised on the failure path but not asserted here (this suite
    -- has no notify stub, same note native_spec.lua gives for its own
    -- sibling case); what's verified is that a walk error degrades gracefully
    -- rather than propagating out of gather().
    local orig_fs_dir = vim.fs.dir
    vim.fs.dir = function()
      return function()
        error("simulated walk failure")
      end
    end
    local ok_call, partial = pcall(files.gather, dir, cfg)
    vim.fs.dir = orig_fs_dir
    H.ok(ok_call, "a walk that fails partway does not raise out of gather()")
    H.eq(#partial, 0, "and yields whatever was gathered before the failure (here: nothing)")

    -- process(): a fake provider, no network, no ui.kit -----------------------
    local translated_calls = {}
    local fake_provider = {
      translate = function(lines, target, _source, _pcfg, cb)
        translated_calls[#translated_calls + 1] = { lines = lines, target = target }
        cb(true, { "TRANSLATED: " .. table.concat(lines, " ") })
      end,
    }

    config.setup({ translate = { history = { enable = false } } })

    local picked =
      { { rel = "a.md", abs = dir .. "/a.md" }, { rel = "sub/b.md", abs = dir .. "/sub/b.md" } }
    local done = false
    files.process(fake_provider, picked, "FR", "suffix", function()
      done = true
    end)
    vim.wait(1000, function()
      return done
    end)
    H.ok(done, "process() runs to completion and calls on_done")
    H.eq(#translated_calls, 2, "the provider was called once per picked file")

    H.eq(vim.fn.filereadable(dir .. "/a.FR.md"), 1, "'suffix' mode writes a sibling file per input")
    H.contains(H.read(dir .. "/a.FR.md"), "TRANSLATED: hello", "with the translated content")
    H.eq(vim.fn.filereadable(dir .. "/sub/b.FR.md"), 1, "including nested files")
    H.eq(vim.fn.filereadable(dir .. "/a.md"), 1, "and the original is left untouched")
    H.eq(H.read(dir .. "/a.md"), "hello", "with its original content")

    -- process(): "replace" mode overwrites the file in place --------------------
    local done2 = false
    files.process(
      fake_provider,
      { { rel = "a.md", abs = dir .. "/a.md" } },
      "DE",
      "replace",
      function()
        done2 = true
      end
    )
    vim.wait(1000, function()
      return done2
    end)
    H.ok(done2, "replace mode completes")
    H.eq(H.read(dir .. "/a.md"), "TRANSLATED: hello", "the original file is overwritten")

    -- process(): ERR-30 -- a file that changed on disk while its translation
    -- was "in flight" is not blindly overwritten in replace mode.
    vim.fn.writefile({ "hello" }, dir .. "/a.md")
    local racing_provider = {
      translate = function(lines, _target, _source, _pcfg, cb)
        -- Simulate a concurrent edit landing during the (here: instant) request.
        vim.fn.writefile({ "edited concurrently" }, dir .. "/a.md")
        cb(true, { "TRANSLATED: " .. table.concat(lines, " ") })
      end,
    }
    local done_race = false
    files.process(
      racing_provider,
      { { rel = "a.md", abs = dir .. "/a.md" } },
      "DE",
      "replace",
      function()
        done_race = true
      end
    )
    vim.wait(1000, function()
      return done_race
    end)
    H.ok(done_race, "process() still completes after a stale write is skipped")
    H.eq(
      H.read(dir .. "/a.md"),
      "edited concurrently",
      "the concurrent edit survives -- the stale translation was not written over it"
    )

    -- process(): "buffers" mode opens a scratch buffer, writes nothing to disk -
    local before_bufs = #vim.api.nvim_list_bufs()
    vim.fn.writefile({ "hello" }, dir .. "/a.md") -- restore for a clean assertion below
    local done3 = false
    files.process(
      fake_provider,
      { { rel = "a.md", abs = dir .. "/a.md" } },
      "ES",
      "buffers",
      function()
        done3 = true
      end
    )
    vim.wait(1000, function()
      return done3
    end)
    H.ok(done3, "buffers mode completes")
    H.ok(#vim.api.nvim_list_bufs() > before_bufs, "a new scratch buffer was created")
    H.eq(H.read(dir .. "/a.md"), "hello", "and the file on disk is untouched")

    -- process(): a provider failure is reported, not left half-done -----------
    local failing_provider = {
      translate = function(_lines, _target, _source, _cfg, cb)
        cb(false, "boom")
      end,
    }
    local done4 = false
    files.process(
      failing_provider,
      { { rel = "a.md", abs = dir .. "/a.md" } },
      "FR",
      "replace",
      function()
        done4 = true
      end
    )
    vim.wait(1000, function()
      return done4
    end)
    H.ok(done4, "on_done still fires after a failed translation")

    -- A provider that throws (e.g. a spawn error that escaped) fails that one
    -- file only: the remaining files are still translated and on_done fires.
    local seen = {}
    local throwing_provider = {
      translate = function(lines, _target, _source, _pcfg, cb)
        seen[#seen + 1] = lines[1]
        if lines[1] == "hello" then
          error("ENAMETOOLONG")
        end
        cb(true, { "OK: " .. lines[1] })
      end,
    }
    local done5 = false
    files.process(
      throwing_provider,
      { { rel = "a.md", abs = dir .. "/a.md" }, { rel = "sub/b.md", abs = dir .. "/sub/b.md" } },
      "IT",
      "suffix",
      function()
        done5 = true
      end
    )
    vim.wait(1000, function()
      return done5
    end)
    H.ok(done5, "a throwing provider does not hang the run")
    H.eq(#seen, 2, "the next file is still attempted")
    H.eq(vim.fn.filereadable(dir .. "/a.IT.md"), 0, "the failed file writes nothing")
    H.eq(vim.fn.filereadable(dir .. "/sub/b.IT.md"), 1, "the other file is translated")

    -- run(): early-return guards, without ever reaching ui.kit -----------------
    files.run("", { dir = dir }) -- no target: warns and returns
    files.run("FR", { dir = dir .. "/does-not-exist" }) -- no files under the dir: info + return

    -- target(): what a cwd/path scope translates ---------------------------------
    H.eq(files.target({ kind = "cwd" }).dir, vim.fn.getcwd(), "cwd → the working directory")
    H.eq(files.target({ kind = "path", path = dir }).dir, dir, "path=<dir> → that directory")
    local ft = files.target({ kind = "path", path = dir .. "/a.md" })
    H.eq(ft.file, dir .. "/a.md", "path=<file> → that one file")
    H.eq(ft.dir, nil, "and no directory to pick from")
    local missing, merr = files.target({ kind = "path", path = dir .. "/nope.md" })
    H.eq(missing, nil, "a path that does not exist has no target")
    H.contains(merr, "no such file or directory", "and says so")

    -- run({ file }): one file, no picker, same write path as the picked files ---
    local orig_registry = package.loaded["language.translate.providers.registry"]
    package.loaded["language.translate.providers.registry"] = {
      resolve = function()
        return fake_provider
      end,
    }
    local orig_kit = package.loaded["ui.kit"]
    local picker_opened = false
    package.loaded["ui.kit"] = {
      select = function()
        picker_opened = true
      end,
    }
    vim.fn.writefile({ "single" }, dir .. "/one.md")
    translated_calls = {}
    files.run("NL", { file = dir .. "/one.md", mode = "suffix" })
    vim.wait(1000, function()
      return vim.fn.filereadable(dir .. "/one.NL.md") == 1
    end)
    H.eq(picker_opened, false, "a single file never opens the picker")
    H.eq(#translated_calls, 1, "the provider is asked once")
    H.contains(H.read(dir .. "/one.NL.md"), "TRANSLATED: single", "and the sibling file is written")
    package.loaded["ui.kit"] = orig_kit
    package.loaded["language.translate.providers.registry"] = orig_registry

    config.setup({})
    cleanup()
  end)
end
