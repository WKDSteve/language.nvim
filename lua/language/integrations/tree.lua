---@module 'language.integrations.tree'
---@brief "Spell check this" and "Translate this" as actions on a node of a tree view.
---@description
--- Registers two actions at `lib.nvim.tree.registry`. A tree that reads the registry (the own tree
--- of filetree.nvim) offers them on every node that is a file or a folder on disk: in its context
--- menu, in its action list, and on a key when one is configured.
---
---   language.check      `:Spellcheck path=<node>`: the review of that file or folder
---   language.translate  `:Translate <lang> path=<node>`: a file is translated, a folder opens the
---                       chooser of its translatable files; the language is
---                       `translate.default_target`, or asked for
---
--- Both go through the Lua facade with a path scope, so they do exactly what the commands do.
---
--- Soft in both directions. The registry is lib.nvim's: without a tree that reads it the entries
--- are never looked at, and without a lib.nvim that has the registry nothing is registered.

local M = {}

M.CHECK = "language.check"
M.TRANSLATE = "language.translate"

---@alias Language.Tree.Key string|string[]|false

---@class Language.Tree.Opts
---@field key? { check?: Language.Tree.Key, translate?: Language.Tree.Key }  Key(s) in the tree buffer, per action (default: none; the actions are in the menu).

---@type (fun(): boolean)[]
local registered = {}

---The path the action runs on: the first node. A check and a translation have one scope per run,
---so with several nodes marked the person is told which one it is instead of the others being
---left out silently.
---@param nodes table[]|nil
---@param verb string  "checking" | "translating"
---@return string|nil path
local function scope_of(nodes, verb)
  local node = nodes and nodes[1]
  if not (node and type(node.path) == "string" and node.path ~= "") then
    return nil
  end
  if #nodes > 1 then
    require("lib.nvim.notify")
      .create("[language]")
      .warn(("%d nodes are marked; %s the first only: %s"):format(#nodes, verb, node.path))
  end
  return node.path
end

---@param path string
---@return string
local function name_of(path)
  local name = vim.fn.fnamemodify(path, ":t")
  return name ~= "" and name or path
end

---Spell check a file or a folder: what `:Spellcheck path=<path>` does.
---@param path string
---@return nil
function M.check(path)
  require("language").spellcheck(nil, { kind = "path", path = path })
end

---Translate a file or a folder: what `:Translate <lang> path=<path>` does. The language is
---`translate.default_target` when that is set; otherwise it is asked for from
---`translate.default_langs`, and a dismissed question translates nothing.
---@param path string
---@return nil
function M.translate(path)
  local function run(lang)
    require("language").translate(lang, { scope = { kind = "path", path = path } })
  end
  local cfg = require("language.config").get().translate
  if type(cfg.default_target) == "string" and cfg.default_target ~= "" then
    run(cfg.default_target)
    return
  end
  require("ui.kit").select({
    items = cfg.default_langs or { "EN", "DE" },
    title = ("Translate %s to…"):format(name_of(path)),
    on_select = function(item)
      if type(item) == "string" and item ~= "" then
        run(item)
      end
    end,
  })
end

---Register the two actions. Without `lib.nvim.tree.registry` (an older lib.nvim) nothing happens.
---@param opts? Language.Tree.Opts
---@return boolean registered
function M.register(opts)
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if not ok or type(registry.action) ~= "function" then
    return false
  end
  M.unregister()
  local key = type(opts) == "table" and type(opts.key) == "table" and opts.key or {}
  registered[#registered + 1] = registry.action({
    name = M.CHECK,
    desc = "Spell check this file or folder (language.nvim)",
    key = key.check or nil,
    needs = { "path" },
    run = function(nodes)
      local path = scope_of(nodes, "checking")
      if path then
        M.check(path)
      end
    end,
  })
  registered[#registered + 1] = registry.action({
    name = M.TRANSLATE,
    desc = "Translate this file or folder (language.nvim)",
    key = key.translate or nil,
    needs = { "path" },
    -- the default file mode writes a translated copy next to each file
    mutates = true,
    run = function(nodes)
      local path = scope_of(nodes, "translating")
      if path then
        M.translate(path)
      end
    end,
  })
  return true
end

---Take the actions out again.
---@return nil
function M.unregister()
  for _, remove in ipairs(registered) do
    remove()
  end
  registered = {}
end

return M
