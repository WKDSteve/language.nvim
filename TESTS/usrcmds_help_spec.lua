-- TESTS/usrcmds_help_spec.lua -- every flag and positional argument of `:Translate`,
-- `:TranslateReplace` and `:Spellcheck` has a line in lib.nvim's option float.
--
-- The flag text comes from the `desc` of each FlagSpec in language.bindings.usrcmds, the argument
-- text from the text of its type (`TRANSLATE_LANG`, `TRANSLATE_SCOPE`, `SPELL_LANG`,
-- `SPELL_SCOPE`: written once, shown for every argument of that type). A new flag or argument
-- without one shows up as a bare row in the cheatsheet, so this fails until it is described.

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked(function()
    local ok, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
    H.ok(ok, "the composer loads")

    -- The case needs `help.undocumented` from lib.nvim: an older checkout fails here by name
    -- instead of skipping the case silently (NEW-43).
    assert(
      type(composer.help.undocumented) == "function",
      "lib.nvim lacks composer.help.undocumented: update lib.nvim, this case cannot run without it"
    )

    require("language.bindings.usrcmds").setup()

    for _, name in ipairs({ "Spellcheck", "Translate", "TranslateReplace" }) do
      H.ok(composer.registry()[name] ~= nil, ":" .. name .. " is registered through the composer")

      local missing = {}
      for _, m in ipairs(composer.help.undocumented(name)) do
        missing[#missing + 1] = m.name
      end
      H.eq(
        #missing,
        0,
        ":" .. name .. " options without a help text: " .. table.concat(missing, ", ")
      )

      local missing_args = {}
      for _, m in ipairs(composer.help.undocumented(name, { args = true })) do
        missing_args[#missing_args + 1] = m.kind .. ":" .. m.name
      end
      H.eq(
        #missing_args,
        0,
        ":" .. name .. " entries without a help text: " .. table.concat(missing_args, ", ")
      )
    end

    -- The type texts follow the house style: one line, no trailing period, at most 80 characters.
    local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
    for _, type_name in ipairs({ "TRANSLATE_LANG", "TRANSLATE_SCOPE", "SPELL_LANG", "SPELL_SCOPE" }) do
      local text = argtypes.get(type_name).desc or ""
      H.ok(text ~= "", type_name .. " has a help text")
      H.ok(
        not text:find("\n", 1, true) and text:sub(-1) ~= "." and #text <= 80,
        type_name .. " text is one line, without a trailing period, <= 80 characters: " .. text
      )
    end

    -- So do the flag texts and the per-value texts of an enum flag.
    ---@param text string|nil
    ---@return boolean
    local function house_style(text)
      return type(text) == "string"
        and text ~= ""
        and not text:find("\n", 1, true)
        and text:sub(-1) ~= "."
        and #text <= 80
    end
    for _, name in ipairs({ "Translate", "TranslateReplace" }) do
      local handle = composer.registry()[name]
      for _, route in ipairs(handle:spec().routes or {}) do
        for _, flag in ipairs(route.flags or {}) do
          H.ok(
            house_style(flag.desc),
            ":" .. name .. " --" .. flag.name .. " text: " .. tostring(flag.desc)
          )
          for value, text in pairs(flag.enum_desc or {}) do
            H.ok(
              house_style(text),
              ":" .. name .. " --" .. flag.name .. "=" .. value .. " text: " .. tostring(text)
            )
          end
        end
      end
    end

    -- The texts must say what the code does, not what one would hope. `--nocode` skips every line
    -- that holds a backtick (translate/filter.lua), prose around the code included, and only for a
    -- text scope: cwd/path=<p> go to run_files and a word to run_region, neither reads it.
    -- A path scope is a file or a directory; both go to run_files.
    local function flag_text(name, flag_name)
      for _, route in ipairs(composer.registry()[name]:spec().routes or {}) do
        for _, flag in ipairs(route.flags or {}) do
          if flag.name == flag_name then
            return flag.desc or ""
          end
        end
      end
      return ""
    end
    for _, name in ipairs({ "Translate", "TranslateReplace" }) do
      local text = flag_text(name, "nocode")
      H.ok(
        text:find("lines with inline code", 1, true) ~= nil,
        ":" .. name .. " --nocode says whole lines are skipped: " .. text
      )
      H.ok(
        text:find("cwd", 1, true) ~= nil and text:find("path", 1, true) ~= nil,
        ":" .. name .. " --nocode names the scopes it does not cover: " .. text
      )
      H.ok(
        text:find("cword", 1, true) ~= nil,
        ":" .. name .. " --nocode names the cword scope too: " .. text
      )
    end
    H.ok(
      flag_text("Translate", "nocode"):find("output=replace", 1, true) ~= nil,
      ":Translate --nocode says it only works with output=replace"
    )

    local scope_text = argtypes.get("TRANSLATE_SCOPE").desc or ""
    H.ok(
      scope_text:find("path=<p>", 1, true) ~= nil,
      "TRANSLATE_SCOPE offers any path (file or directory): " .. scope_text
    )
    H.ok(
      scope_text:find("path=<dir>", 1, true) == nil,
      "TRANSLATE_SCOPE no longer limits path= to a directory: " .. scope_text
    )
    H.ok(
      scope_text:find("visible", 1, true) ~= nil,
      "TRANSLATE_SCOPE lists the visible scope: " .. scope_text
    )
  end)
end
