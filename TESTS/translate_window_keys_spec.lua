-- TESTS/translate_window_keys_spec.lua — language.translate.window: the keys of the interactive
-- window (<C-l> retarget, <C-r> reverse, <C-h> history, <C-y> copy, q close) and the target
-- picker of open(). The real ui.kit is loaded; the calls that would open a picker, the engine
-- refresh and the history file are replaced by recorders.

return function(H)
  H.tracked(function()
    local kit = require("ui.kit")
    local window = require("language.translate.window")
    local history = require("language.translate.history")

    local restores = {}
    local function patch(tbl, key, value)
      restores[#restores + 1] = { tbl, key, tbl[key] }
      tbl[key] = value
    end

    local ok, err = pcall(function()
      require("language.config").setup({ translate = { default_target = "" } })

      local selects = {}
      patch(kit, "select", function(opts)
        selects[#selects + 1] = opts
      end)
      local refreshed = 0
      patch(window, "refresh", function()
        refreshed = refreshed + 1
      end)

      -- open() without a target asks for one, then launches the window
      window.open({})
      H.eq(#selects, 1, "no default target: the language picker opens")
      H.falsy(window.is_open(), "and no window yet")
      selects[1].on_select("")
      H.falsy(window.is_open(), "an empty choice opens nothing")
      selects[1].on_select("DE")
      H.ok(window.is_open(), "choosing a language opens the window")

      local st = window._state()
      local function key(lhs)
        return vim.api.nvim_buf_call(st.input_buf, function()
          return vim.fn.maparg(lhs, "n", false, true)
        end)
      end
      local function title()
        local cfg = vim.api.nvim_win_get_config(st.input_win).title
        return type(cfg) == "table" and cfg[1][1] or cfg
      end
      H.contains(title(), "DE", "the title names the target")
      for _, lhs in ipairs({ "q", "<Esc>", "<C-l>", "<C-r>", "<C-h>", "<C-y>" }) do
        H.ok(key(lhs).callback ~= nil, lhs .. " is mapped in the input buffer")
      end

      -- <C-l>: retarget picker
      key("<C-l>").callback()
      H.eq(#selects, 2, "<C-l> opens the target picker")
      selects[2].on_select("FR")
      H.contains(title(), "FR", "choosing a language changes the title")
      H.eq(refreshed, 1, "and re-translates")
      window.retarget("")
      H.contains(title(), "FR", "an empty target is ignored")
      H.eq(refreshed, 1, "without a refresh")

      -- <C-r>: nothing to reverse while the output is empty
      key("<C-r>").callback()
      H.eq(#selects, 2, "<C-r> with an empty output does nothing")

      -- <C-r>: the translation becomes the input, then a new target is asked
      vim.api.nvim_set_option_value("modifiable", true, { buf = st.output_buf })
      vim.api.nvim_buf_set_lines(st.output_buf, 0, -1, false, { "hallo", "welt" })
      vim.api.nvim_set_option_value("modifiable", false, { buf = st.output_buf })
      key("<C-r>").callback()
      H.eq(
        table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), "|"),
        "hallo|welt",
        "<C-r> promotes the output to the input"
      )
      H.eq(#selects, 3, "and asks for the next target")

      -- <C-y>: copies the output and records the pair
      local recorded
      patch(history, "record", function(entry)
        recorded = entry
      end)
      key("<C-y>").callback()
      H.eq(vim.fn.getreg('"'), "hallo\nwelt", "<C-y> copies the translation")
      H.eq(recorded.target, "FR", "and records the target")
      H.eq(table.concat(recorded.output, "|"), "hallo|welt", "with the output")

      -- <C-h>: a history entry fills the input and sets its target
      patch(history, "pick", function(cb)
        cb({ input = { "from history" }, target = "ES" })
      end)
      key("<C-h>").callback()
      H.eq(
        table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), "|"),
        "from history",
        "<C-h> loads the chosen entry into the input"
      )
      H.contains(title(), "ES", "and takes its target")

      -- q closes
      key("q").callback()
      H.falsy(window.is_open(), "q closes the window")
    end)

    window.close()
    for i = #restores, 1, -1 do
      local r = restores[i]
      r[1][r[2]] = r[3]
    end
    if not ok then
      error(err, 0)
    end
  end)
end
