-- TESTS/harness.lua — tiny assertion helper shared by the spec files.
-- Handed to each spec by testing.nvim (dialect "h", see .testing.lua).

local H = {}

--- Assert equality; raises a descriptive error on mismatch (caught by the runner).
---@param a any # actual
---@param b any # expected
---@param msg string|nil
function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

--- Assert a truthy value.
---@param v any
---@param msg string|nil
function H.ok(v, msg)
  if not v then
    error(("FAIL %s: expected truthy, got %q"):format(msg or "", tostring(v)), 2)
  end
end

--- Assert a falsy value.
---@param v any
---@param msg string|nil
function H.falsy(v, msg)
  if v then
    error(("FAIL %s: expected falsy, got %q"):format(msg or "", tostring(v)), 2)
  end
end

--- Assert that `haystack` contains `needle` as a literal substring.
---@param haystack string
---@param needle string
---@param msg string|nil
function H.contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error(("FAIL %s: %q does not contain %q"):format(msg or "", tostring(haystack), needle), 2)
  end
end

--- Assert that `haystack` does NOT contain `needle`.
---@param haystack string
---@param needle string
---@param msg string|nil
function H.excludes(haystack, needle, msg)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    error(("FAIL %s: %q still contains %q"):format(msg or "", tostring(haystack), needle), 2)
  end
end

--- A scratch directory inside the repository, removed by `cleanup()`.
---
--- Inside the repo rather than in `vim.fn.tempname()` on purpose: on Windows
--- the temp path carries an 8.3 short component (`STEFAN~1`), which several
--- Vim path builtins do not see through -- a fixture there would pass on Linux
--- and quietly assert nothing locally.
---@param name string
---@return string dir, fun() cleanup
function H.fixture(name)
  local dir = vim.fs.normalize(vim.fn.getcwd()) .. "/TESTS/.fixture-" .. name
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  return dir, function()
    vim.fn.delete(dir, "rf")
  end
end

local KEYMAP_MODES = { "n", "i", "x", "s", "o", "c", "t", "l" }

--- The fields that make two global maps of one lhs the same map.
local KEYMAP_FIELDS =
  { "rhs", "callback", "expr", "noremap", "silent", "nowait", "desc", "replace_keycodes", "script" }

--- The fields that make two user commands of one name the same command.
local COMMAND_FIELDS = {
  "definition",
  "callback",
  "nargs",
  "bang",
  "bar",
  "register",
  "range",
  "count",
  "addr",
  "complete",
  "complete_arg",
  "keepscript",
  "preview",
}

---@param a table
---@param b table
---@param fields string[]
---@return boolean
local function same(a, b, fields)
  for _, f in ipairs(fields) do
    if a[f] ~= b[f] then
      return false
    end
  end
  return true
end

--- Every global map, keyed by `mode .. "\0" .. lhs`, as `nvim_get_keymap` returns it.
---@return table<string, table>
local function keymap_snapshot()
  local snap = {}
  for _, mode in ipairs(KEYMAP_MODES) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      snap[mode .. "\0" .. m.lhs] = m
    end
  end
  return snap
end

--- Put the global maps back to `before`: delete the added ones, re-set the
--- replaced and the removed ones from their recorded definition.
---@param before table<string, table>
local function restore_keymaps(before)
  local now = keymap_snapshot()
  for key, m in pairs(now) do
    local mode = key:match("^[^%z]+")
    local old = before[key]
    if not old or not same(old, m, KEYMAP_FIELDS) then
      pcall(vim.api.nvim_del_keymap, mode, m.lhs)
    end
  end
  for key, old in pairs(before) do
    local mode = key:match("^[^%z]+")
    local m = now[key]
    if not m or not same(old, m, KEYMAP_FIELDS) then
      pcall(vim.fn.mapset, mode, false, old)
    end
  end
end

--- Re-create a user command from what `nvim_get_commands` reported for it.
---@param name string
---@param c table
local function create_command(name, c)
  local opts = {
    nargs = c.nargs,
    bang = c.bang,
    bar = c.bar,
    register = c.register,
    keepscript = c.keepscript,
    addr = c.addr,
    preview = c.preview,
  }
  if c.range == "." then
    opts.range = true
  elseif c.range == "%" then
    opts.range = "%"
  elseif c.range then
    opts.range = tonumber(c.range)
  end
  if c.count then
    opts.count = tonumber(c.count)
  end
  if c.complete_arg then
    opts.complete = c.complete .. "," .. c.complete_arg
  else
    opts.complete = c.complete
  end
  local command = c.definition
  if c.callback then
    command = c.callback
    opts.desc = c.definition
  end
  pcall(vim.api.nvim_create_user_command, name, command, opts)
end

--- Put the global user commands back to `before`: delete the added ones,
--- re-create the replaced and the removed ones.
---@param before table<string, table>
local function restore_commands(before)
  local now = vim.api.nvim_get_commands({})
  for name, c in pairs(now) do
    local old = before[name]
    if not old then
      pcall(vim.api.nvim_del_user_command, name)
    elseif not same(old, c, COMMAND_FIELDS) then
      create_command(name, old)
    end
  end
  for name, old in pairs(before) do
    if not now[name] then
      create_command(name, old)
    end
  end
end

---@return table<integer, true>
local function autocmd_ids()
  local set = {}
  for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
    if a.id then
      set[a.id] = true
    end
  end
  return set
end

---@generic T
---@param list T[]
---@return table<T, true>
local function to_set(list)
  local set = {}
  for _, v in ipairs(list) do
    set[v] = true
  end
  return set
end

--- Record the editor state a spec is about to change, and return a function
--- that puts it back: buffers and windows created since are wiped / closed,
--- autocmds created since are deleted, global keymaps and user commands are
--- brought back to their recorded state (added ones deleted, replaced or
--- removed ones set again from their recorded definition), and the named
--- global options get their old value back.
---
--- Every spec file runs in an editor of its own (`isolated = "file"`), but the
--- cases of one file share it, so what one case leaves (`setup()`'s :Commands,
--- the language_nvim autocmds, scratch buffers) would reach the next one, and
--- the state guard of testing.nvim reports what a file leaves as a leak.
--- Prefer `H.tracked`, which also restores when an assertion fails half-way.
---@param opts? { options?: string[] }
---@return fun()
function H.track(opts)
  local options = {}
  for _, name in ipairs((opts or {}).options or {}) do
    options[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  local wins = to_set(vim.api.nvim_list_wins())
  local bufs = to_set(vim.api.nvim_list_bufs())
  local cmds = vim.api.nvim_get_commands({})
  local maps = keymap_snapshot()
  local aus = autocmd_ids()
  local start_win = vim.api.nvim_get_current_win()

  return function()
    if vim.api.nvim_win_is_valid(start_win) then
      pcall(vim.api.nvim_set_current_win, start_win)
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if not wins[win] then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not bufs[buf] then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    restore_commands(cmds)
    restore_keymaps(maps)
    for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
      if a.id and not aus[a.id] then
        pcall(vim.api.nvim_del_autocmd, a.id)
      end
    end
    for name, value in pairs(options) do
      vim.api.nvim_set_option_value(name, value, { scope = "global" })
    end
  end
end

--- Run `body` between `H.track(opts)` and its restore, and restore even when
--- `body` raises (a failed `H.eq` half-way through a spec): the error is
--- raised again afterwards, unchanged. `opts` may be left out.
---@param opts? { options?: string[] }|fun()
---@param body? fun()
function H.tracked(opts, body)
  if type(opts) == "function" then
    opts, body = nil, opts
  end
  assert(type(body) == "function", "H.tracked: body must be a function")
  local restore = H.track(opts --[[@as { options?: string[] }|nil]])
  local ok, err = pcall(body)
  restore()
  if not ok then
    error(err, 0)
  end
end

--- Read a file back as one string.
---@param path string
---@return string
function H.read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return ""
  end
  return table.concat(lines, "\n")
end

return H
