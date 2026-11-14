---@diagnostic disable: missing-fields
-- The config tables below carry only the fields the case exercises; a
-- resolved LanguageConfig per case would be noise, not coverage.
-- TESTS/config_spec.lua — language.config: the merge, and that DEFAULTS is not
-- mutated by it.

return function(H)
  local config = require("language.config")
  local DEFAULTS = require("language.config.DEFAULTS")

  -- The first scalar option by name, not by `pairs` order: which key a hash walk yields first
  -- changes with the set of options, and the case must not change with it.
  local names = vim.tbl_keys(DEFAULTS)
  table.sort(names)
  local key, original
  for _, k in ipairs(names) do
    local v = DEFAULTS[k]
    if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
      key, original = k, v
      break
    end
  end
  H.ok(key, "DEFAULTS has at least one scalar option to test against")

  local fresh = config.get()
  H.eq(fresh[key], original, "get() before setup() returns the defaults")
  H.ok(fresh ~= DEFAULTS, "as a copy, not the DEFAULTS table itself")

  -- Not `a and not original or ...`: for `true` that falls through to the string branch.
  local changed
  if type(original) == "boolean" then
    changed = not original
  elseif type(original) == "number" then
    changed = original + 1
  else
    changed = tostring(original) .. "-changed"
  end
  ---@diagnostic disable-next-line: assign-type-mismatch
  config.setup({ [key] = changed })
  H.eq(config.get()[key], changed, "a user value wins")
  H.eq(DEFAULTS[key], original, "DEFAULTS itself was not mutated")

  config.setup({})
  H.eq(config.get()[key], original, "setup({}) restores the defaults")
end
