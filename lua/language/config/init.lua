---@module 'language.config'
---@brief Merges user options (from setup()) over the plugin's defaults.
---@description
--- See config/DEFAULTS.lua for the default values and config/@types for their
--- types. Use `get()` to read the active configuration; never mutate the
--- returned table.

require("language.config.@types")

local M = {}

---@type LanguageConfig
local defaults = require("language.config.DEFAULTS")

--- Only the top-level keys are checked: below them the defaults leave options out on purpose
--- (`spell.providers.native.spelllang = nil` means "inherit 'spelllang'", `custom` is nil), so a
--- schema inferred from the defaults would call a real option unknown.
local ANY = "boolean|number|string|table|function"
---@type table<string, string>
local SCHEMA = {}
for key in pairs(defaults) do
  SCHEMA[key] = ANY
end

local cfg = require("lib.lua.config").new(defaults, {
  name = "language",
  schema = SCHEMA,
  normalize = function(opts)
    -- `keymaps = false` / `true` is the agreed boolean spelling of the switch
    -- group (`{ enable = false }`); anything else keeps the default.
    if opts.keymaps ~= nil then
      vim.validate("opts.keymaps", opts.keymaps, { "table", "boolean" })
      opts.keymaps = require("lib.nvim.normalize").normalize_switch_group(opts.keymaps)
    end
    -- `tree`: a switch, or a table with the key(s) of the two tree actions.
    if opts.tree ~= nil then
      vim.validate("opts.tree", opts.tree, { "table", "boolean" })
      if type(opts.tree) == "table" then
        vim.validate("opts.tree.key", opts.tree.key, "table", true)
        for _, action in ipairs({ "check", "translate" }) do
          vim.validate(
            "opts.tree.key." .. action,
            (opts.tree.key or {})[action],
            { "string", "table", "boolean" },
            true
          )
        end
      end
    end
  end,
  notify = function(message)
    require("lib.nvim.notify").create("[language]").warn(message)
  end,
})

---Set the options over the defaults. Every call starts from the defaults.
---@param opts LanguageOpts|nil
---@return nil
function M.setup(opts)
  -- A wrong shape fails here with the option's name, not deep inside the merge.
  vim.validate("opts", opts, "table", true)
  cfg.setup(opts)
end

---Return the active configuration.
---@return LanguageConfig
function M.get()
  return cfg.get()
end

return M
