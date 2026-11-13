-- TESTS/translate_motion_spec.lua — language.translate.motion: the
-- operator/visual dispatch that turns a moved-over range into a
-- `language.translate.run`/`run_region` call. `language.translate` is
-- stubbed (hover_spec.lua's technique) so this never reaches a real
-- provider or `ui.kit`'s language picker — `force_target`/`default_target`
-- are used throughout specifically to keep `choose_target` off the `ui.kit`
-- path entirely, since that module is not available in this suite's CI
-- checkout (see TESTS/README.md).

return function(H)
  -- Put back what this spec creates, also on failure (see H.tracked): the state guard reports a leak.
  H.tracked({ options = { "operatorfunc" } }, function()
    local config = require("language.config")

    ---@type table[]
    local run_calls, run_region_calls

    local function stub_translate()
      run_calls, run_region_calls = {}, {}
      package.loaded["language.translate"] = {
        run = function(lang, opts)
          run_calls[#run_calls + 1] = { lang = lang, opts = opts }
        end,
        run_region = function(lang, opts)
          run_region_calls[#run_region_calls + 1] = { lang = lang, opts = opts }
        end,
      }
    end

    local function reload_motion()
      package.loaded["language.translate.motion"] = nil
      return require("language.translate.motion")
    end

    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one two three", "four five six" })
    vim.api.nvim_set_current_buf(buf)

    config.setup({ translate = { default_target = "FR" } })
    stub_translate()
    local motion = reload_motion()

    -- operator(): line-wise motion (no getregionpos span) -> run() over a
    -- selection scope spanning the moved-over lines.
    vim.api.nvim_buf_set_mark(buf, "[", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, "]", 2, 0, {})
    motion.operator("line")
    H.eq(#run_calls, 1, "a line motion dispatches through run()")
    H.eq(run_calls[1].lang, "FR", "using the configured default_target")
    H.eq(run_calls[1].opts.output, "replace", "motions always replace in place")
    H.eq(run_calls[1].opts.scope.kind, "selection", "over a selection scope")
    H.eq(run_calls[1].opts.scope.range.s, 1, "spanning the marked lines")
    H.eq(run_calls[1].opts.scope.range.e, 2, "start to end")

    -- force_target(): one-shot, consumed by the very next run -----------------
    config.setup({ translate = { default_target = nil } })
    stub_translate()
    motion = reload_motion()
    motion.force_target("DE")
    vim.api.nvim_buf_set_mark(buf, "[", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, "]", 1, 0, {})
    motion.operator("line")
    H.eq(run_calls[1].lang, "DE", "the forced target wins over an unset default_target")

    -- expr(): arms operatorfunc and returns the g@ trigger ---------------------
    local expr = motion.expr()
    H.eq(expr, "g@", "expr() returns the g@ trigger")
    H.eq(
      vim.o.operatorfunc,
      "v:lua.require'language.translate.motion'.operator",
      "and arms operatorfunc at the same v:lua path every time"
    )

    -- visual(): line-wise selection (mode 'V') falls back to the line range --
    config.setup({ translate = { default_target = "FR" } })
    stub_translate()
    motion = reload_motion()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    motion.visual()
    H.eq(#run_calls, 1, "a linewise visual selection dispatches through run()")
    H.eq(run_calls[1].opts.scope.kind, "selection", "as a selection scope, not run_region")

    vim.api.nvim_buf_delete(buf, { force = true })
    package.loaded["language.translate"] = nil
    package.loaded["language.translate.motion"] = nil
    config.setup({})
  end)
end
