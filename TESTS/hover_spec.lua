-- TESTS/hover_spec.lua — language.hover: the word under the cursor, translated
-- into a hover.nvim float.
--
-- No network. The translate provider is stubbed, and so is hover.nvim itself:
-- the point of every assertion here is the wiring and the refusals, not the
-- translation. What cannot be checked without a person is whether the endpoint
-- answers at all -- measured 2026-09-03 it answered HTTP 429, which is exactly
-- why the failure path below has assertions of its own.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked(function()
    local config = require("language.config")

    ---@type string[]
    local registered_as = {}
    ---@type table<string, any>
    local contribution = {}

    --- A stand-in for hover.nvim's registry, recording what it was handed.
    local function stub_hover()
      package.loaded["hover.registry"] = {
        register = function(name, contrib)
          registered_as[#registered_as + 1] = name
          contribution = contrib
        end,
        contributors = function()
          local positions, on_request = 0, 0
          for _, entry in ipairs((contribution or {}).positions or {}) do
            positions = positions + 1
            if entry.on_request then
              on_request = on_request + 1
            end
          end
          if positions == 0 then
            return {}
          end
          return { { name = "language.nvim", positions = positions, on_request = on_request } }
        end,
      }
    end

    --- A stand-in for the translate provider chain. `answer` is what its
    --- callback is handed; it fires synchronously, so `vim.wait` returns at once.
    ---@param ok boolean
    ---@param answer any
    local function stub_provider(ok, answer)
      package.loaded["language.translate.providers.registry"] = {
        resolve = function()
          return {
            name = "stub",
            translate = function(_lines, _target, _source, _cfg, cb)
              cb(ok, answer)
              return nil
            end,
          }
        end,
      }
    end

    local function reload_hover()
      package.loaded["language.hover"] = nil
      return require("language.hover")
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "the threshold is deliberate",
      "  42 == 0x1f",
      "ein Wort mit Umlaut: Größe",
    })

    -- The word under the cursor ------------------------------------------------
    local scope = require("language.scope")
    H.eq(scope.cword_at(buf, 1, 4), "threshold", "the word the column lands inside")
    H.eq(scope.cword_at(buf, 1, 0), "the", "and at its first byte")
    H.eq(scope.cword_at(buf, 1, 3), nil, "a space is not in a word")
    H.eq(scope.cword_at(buf, 1, 500), nil, "past the end of the line is not a word")
    H.eq(scope.cword_at(buf, 99, 0), nil, "past the end of the buffer is not a word")

    -- A run with no letter in it is not something to spend a round trip on.
    H.eq(scope.cword_at(buf, 2, 2), nil, "digits alone are not a word")

    -- Bytes above 0x7F are letters: a word that is entirely non-ASCII must not
    -- be declined by the "has a letter" guard, which `%a` alone would do.
    H.eq(scope.cword_at(buf, 3, 22), "Größe", "a word with an umlaut survives the letter guard")

    local region = scope.cword_region(buf, 1, 4)
    H.ok(region, "a word yields a region")
    -- `H.ok` is a runtime assertion and tells the analyser nothing; the cast is
    -- what says "past this line it is not nil" to a reader and to LuaLS alike.
    ---@cast region -nil
    H.eq(region.sr, 0, "rows are 0-based")
    H.eq(region.sc, 4, "and start at the word's first byte")
    H.eq(region.ec, 13, "and end one past its last, the shape nvim_buf_get_text takes")
    H.eq(
      vim.api.nvim_buf_get_text(buf, region.sr, region.sc, region.er, region.ec, {})[1],
      "threshold",
      "the region really names the word"
    )
    H.eq(scope.cword_region(buf, 1, 3), nil, "no word, no region")

    -- The scope word -----------------------------------------------------------
    -- `cword` has to parse as a scope rather than fall into `rest`: in `rest` it
    -- would be read as a second language code and the command would translate
    -- the whole buffer instead.
    local s, rest = scope.parse({ "DE", "cword" }, { bufnr = buf })
    H.eq(s.kind, "cword", "cword is a scope word")
    H.eq(rest[1], "DE", "and the language is still left over for the caller")
    H.eq(#rest, 1, "only the language")

    -- The target language ------------------------------------------------------
    config.setup({})
    local hover = reload_hover()
    H.eq(hover.target(), "EN", "with no default_target the hover translates into English")

    config.setup({ translate = { default_target = "DE" } })
    H.eq(hover.target(), "DE", "a configured default_target moves the hover too")

    -- Declining vs failing -----------------------------------------------------
    -- Declining is not the same as failing, and hover.nvim treats them
    -- differently: a decline is not a page the reader has to step past.
    stub_provider(true, { "Schwelle" })
    H.eq(hover.position(buf, 1, 3), nil, "no word under the cursor: declined, not answered")

    local content = hover.position(buf, 1, 4)
    H.ok(content, "a word under the cursor is answered")
    ---@cast content -nil
    H.eq(content.lines[1], "Schwelle", "the provider's answer is the content")
    H.contains(content.title, "threshold", "the title names the word")
    H.contains(content.title, "DE", "and the language it went into")
    H.eq(content.highlight, nil, "a good answer carries no error highlight")

    -- The failure path, which is not hypothetical -------------------------------
    -- Measured 2026-09-03: the keyless Google endpoint answers over quota with
    -- an HTML page, and the provider reports that as "invalid translation
    -- response" -- true, and indistinguishable from a parse bug. A reader who
    -- gets that deserves to know it was the endpoint.
    stub_provider(false, "invalid translation response")
    local failed = hover.position(buf, 1, 4)
    H.ok(failed, "a failure after a word was found still answers")
    ---@cast failed -nil
    H.eq(failed.highlight, "HoverError", "and says so in the way hover.nvim renders errors")
    H.contains(failed.lines[1], "threshold", "the word is still named")
    H.contains(failed.lines[1], "rate limit", "and the HTML page is called what it is")

    --- The first line of whatever the hover answers for `threshold`, having
    --- asserted that it answered at all. Three near-identical assertions
    --- followed, each indexing a nilable return in place.
    ---@return string
    local function first_line()
      local c = hover.position(buf, 1, 4)
      H.ok(c, "the hover declined where it was expected to answer")
      ---@cast c -nil
      return c.lines[1]
    end

    stub_provider(false, "<html><head><title>Sorry...</title></head>")
    H.contains(
      first_line(),
      "rate limit",
      "the raw page is recognised too, not only the provider's wording for it"
    )

    stub_provider(false, "curl not found")
    H.contains(
      first_line(),
      "curl not found",
      "an unrelated failure is passed through rather than relabelled"
    )

    stub_provider(true, {})
    H.contains(
      first_line(),
      "nothing",
      "an empty success is a failure: an empty float would look like a decline"
    )

    -- Registration -------------------------------------------------------------
    stub_hover()
    registered_as, contribution = {}, {}

    config.setup({ hover = false })
    hover = reload_hover()
    H.falsy(hover.setup(), "hover = false registers nothing")
    H.eq(#registered_as, 0, "and really does not call register")

    config.setup({ hover = true })
    hover = reload_hover()
    H.ok(hover.setup(), "the default registers")
    H.eq(registered_as[1], "language.nvim", "under the plugin's own name")
    H.eq(#contribution.positions, 1, "one position preview")
    -- Read through a `type` guard rather than indexed straight: registered as a
    -- bare function -- the shape that means "ask me on every trigger" -- this
    -- would raise instead of failing, and a spec that explodes says less than one
    -- that reports.
    local entry = contribution.positions[1]
    H.eq(
      type(entry),
      "table",
      "the position is registered in the on_request shape, not as a bare function"
    )
    H.eq(
      entry.on_request,
      true,
      "and on_request -- without it the automatic trigger would translate every word rested on"
    )
    H.ok(hover.registered(), "and the registry reports it back")

    -- Without hover.nvim at all, this is not a failure but a machine that has
    -- the optional half missing.
    package.loaded["hover.registry"] = nil
    hover = reload_hover()
    H.falsy(hover.setup(), "no hover.nvim: nothing registered, and no error")
    H.falsy(hover.registered(), "and nothing claims to be registered")

    package.loaded["hover.registry"] = nil
    package.loaded["language.translate.providers.registry"] = nil
    package.loaded["language.hover"] = nil
    config.setup({})
  end)
end
