---@module 'language.spell.providers.native'
---@brief Native spell provider built on Neovim's own `vim.spell.check`.
---@description
--- Always available (no external tools). Respects the window `spelllang`.
--- Scope-aware: buffer/visible/selection scan line ranges of an open buffer;
--- cwd/path scan text files (open buffers preferred; unopened files are read
--- with `vim.fn.readfile`).
---
--- Config-gated refinements:
---   • word_split — split CamelCase/snake_case tokens and only report real
---     misspelled subwords (precise spans), dropping code-identifier false
---     positives.
---   • regions.skip_urls / skip_emails — drop errors inside URL/email spans.
---   • skip_readonly — never scan readonly buffers.

require("language.spell.@types")

local api = vim.api
local fn = vim.fn

local split = require("language.spell.core.split")
local notify = require("lib.nvim.notify").create("[language.spell]")

local M = {}

M.name = "native"
M.supports = { buffer = true, cwd = true, grammar = false }

---Map a `vim.spell.check` error type to the issue `kind`.
---@type table<string, LanguageSpellKind>
local KIND = { bad = "spell", rare = "rare", caps = "caps", ["local"] = "spell" }

---Text-file extensions considered when scanning cwd/path directories.
---@type table<string, true>
local TEXT_EXT = {
  lua = true,
  md = true,
  txt = true,
  rst = true,
  vim = true,
  toml = true,
  yaml = true,
  yml = true,
  json = true,
  ts = true,
  js = true,
  py = true,
  sh = true,
  zsh = true,
  fish = true,
  c = true,
  cpp = true,
  h = true,
  go = true,
  rs = true,
  java = true,
  rb = true,
  html = true,
  css = true,
  tex = true,
  bib = true,
  adoc = true,
  asciidoc = true,
}

---Is the native spell API present?
---@see LanguageSpellProvider
---@return boolean
function M.available()
  return type(vim.spell) == "table" and type(vim.spell.check) == "function"
end

---@internal
---Whole-word "is this misspelled" check for a lone (sub)word.
---@param word string
---@return boolean
local function is_bad(word)
  local errs = vim.spell.check(word)
  return #errs > 0 and errs[1][1] == word
end

---@internal
---Compute 1-based [start,end) byte spans on `line` that should be skipped
---(URLs, emails) per config. Returns nil when nothing is configured.
---@param line string
---@param regions LanguageSpellRegionsCfg
---@return { [1]: integer, [2]: integer }[]|nil
local function skip_spans(line, regions)
  if not (regions and (regions.skip_urls or regions.skip_emails)) then
    return nil
  end
  local spans = {}
  if regions.skip_urls then
    for s, e in line:gmatch("()%a[%w+.%-]*://[%w./%-_?=&#%%~:@!$'()*+,;]+()") do
      spans[#spans + 1] = { s, e }
    end
    for s, e in line:gmatch("()www%.[%w./%-_?=&#%%~:@]+()") do
      spans[#spans + 1] = { s, e }
    end
  end
  if regions.skip_emails then
    for s, e in line:gmatch("()[%w._%%+%-]+@[%w.%-]+%.%a%a+()") do
      spans[#spans + 1] = { s, e }
    end
  end
  return #spans > 0 and spans or nil
end

---@internal
---@param col integer                     1-based
---@param spans { [1]: integer, [2]: integer }[]|nil
---@return boolean
local function in_skip_span(col, spans)
  if not spans then
    return false
  end
  for _, sp in ipairs(spans) do
    if col >= sp[1] and col < sp[2] then
      return true
    end
  end
  return false
end

---@internal
---Build a single issue.
---@param word string
---@param kind_key string
---@param col integer                     1-based byte column
---@param lnum integer
---@param bufnr integer|nil
---@param path string
---@return LanguageSpellIssue
local function make_issue(word, kind_key, col, lnum, bufnr, path)
  return {
    bufnr = bufnr,
    path = path,
    lnum = lnum,
    col = col,
    end_col = col + #word,
    word = word,
    kind = KIND[kind_key] or "spell",
    source = "native",
  }
end

---@internal
---Expand a flagged token into precise subword issues (word_split). Returns true
---if at least one real misspelling was emitted; false means the token was a
---code-identifier false positive and should be dropped.
---@param word string
---@param kind_key string
---@param col integer
---@param lnum integer
---@param bufnr integer|nil
---@param path string
---@param min_length integer
---@param out LanguageSpellIssue[]
---@return boolean emitted
local function emit_split(word, kind_key, col, lnum, bufnr, path, min_length, out)
  local emitted = false
  for _, part in ipairs(split.split(word)) do
    if #part.sub >= min_length and is_bad(part.sub) then
      out[#out + 1] = make_issue(part.sub, kind_key, col + part.offset, lnum, bufnr, path)
      emitted = true
    end
  end
  return emitted
end

---@internal
---Compute which line indices are silenced by inline `language:disable-*`
---directives, and whether the whole file is disabled.
---  `language:disable-file`       — skip the entire buffer
---  `language:disable-line`       — skip the line the directive is on
---  `language:disable-next-line`  — skip the following line
---@param lines string[]
---@return table<integer, true> disabled, boolean whole_file
local function disabled_lines(lines)
  ---@type table<integer, true>
  local disabled = {}
  local whole_file = false
  for i = 1, #lines do
    local line = lines[i]
    if line:find("language:disable%-file") then
      whole_file = true
    end
    if line:find("language:disable%-next%-line") then
      disabled[i + 1] = true
    elseif line:find("language:disable%-line") then
      disabled[i] = true
    end
  end
  return disabled, whole_file
end

---@internal
---Scan `lines` for spelling errors and append `LanguageSpellIssue`s to `out`.
---@param lines string[]
---@param first_lnum integer 1-based line number of `lines[1]` in the buffer
---@param bufnr integer|nil nil = unloaded file, no attached buffer
---@param path string
---@param out LanguageSpellIssue[] appended to in place
---@param cfg LanguageSpellCfg
---@param spellable? fun(lnum: integer, col: integer): boolean  # nil = treat all text as spellable
---@return nil
local function scan_lines(lines, first_lnum, bufnr, path, out, cfg, spellable)
  local check = vim.spell.check
  local ws = cfg.word_split or {}
  local do_split = ws.enable == true
  local min_length = ws.min_length or 4
  local regions = cfg.regions

  local disabled, whole_file = disabled_lines(lines)
  if whole_file then
    return
  end

  for i = 1, #lines do
    local line = lines[i]
    local errs = (not disabled[i]) and check(line) or {}
    if #errs > 0 then
      local spans = skip_spans(line, regions)
      local lnum = first_lnum + i - 1
      for j = 1, #errs do
        local entry = errs[j]
        local word, kind_key, col = entry[1], entry[2], entry[3] or 1
        if col < 1 then
          col = 1
        end
        if not in_skip_span(col, spans) and (not spellable or spellable(lnum, col)) then
          if do_split and split.is_compound(word) then
            emit_split(word, kind_key, col, lnum, bufnr, path, min_length, out)
          else
            out[#out + 1] = make_issue(word, kind_key, col, lnum, bufnr, path)
          end
        end
      end
    end
  end
end

---@internal
---Should this buffer be scanned at all (readonly gate)?
---@param bufnr integer
---@param cfg LanguageSpellCfg
---@return boolean
local function scannable(bufnr, cfg)
  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if cfg.skip_readonly then
    local ok, ro = pcall(api.nvim_get_option_value, "readonly", { buf = bufnr })
    if ok and ro then
      return false
    end
  end
  return true
end

---@internal
---Build a spellable-position predicate from Treesitter @spell regions, or nil
---when region restriction is disabled/unavailable (then all text is spellable).
---@param bufnr integer
---@param cfg LanguageSpellCfg
---@return (fun(lnum: integer, col: integer): boolean)|nil
local function region_predicate(bufnr, cfg)
  if not (cfg.regions and cfg.regions.treesitter_spell) then
    return nil
  end
  local regions = require("language.spell.core.regions").build(bufnr)
  if not regions then
    return nil
  end
  local is_spellable = require("language.spell.core.regions").is_spellable
  return function(lnum, col)
    return is_spellable(regions, lnum, col)
  end
end

---@internal
---Collect issues from a buffer line range (1-based, inclusive).
---@param bufnr integer
---@param s integer
---@param e integer
---@param out LanguageSpellIssue[]
---@param cfg LanguageSpellCfg
---@return nil
local function collect_buf_range(bufnr, s, e, out, cfg)
  if not scannable(bufnr, cfg) then
    return
  end
  local total = api.nvim_buf_line_count(bufnr)
  s = math.max(1, s)
  e = math.min(total, e)
  if e < s then
    return
  end
  local lines = api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local spellable = region_predicate(bufnr, cfg)
  scan_lines(lines, s, bufnr, api.nvim_buf_get_name(bufnr), out, cfg, spellable)
end

---@internal
---Collect issues from a file on disk (not necessarily loaded).
---@param path string
---@param out LanguageSpellIssue[]
---@param cfg LanguageSpellCfg
---@return boolean ok
---@return string|nil err  reason nothing was collected, when `ok` is false
local function collect_file(path, out, cfg)
  if fn.filereadable(path) ~= 1 then
    return false, "not readable: " .. path
  end
  local ok, lines = pcall(fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return false, "failed to read " .. path .. ": " .. tostring(lines)
  end
  -- Unloaded files have no attached parser; scan all text (no region predicate).
  scan_lines(lines, 1, nil, path, out, cfg, nil)
  return true, nil
end

---@internal
---Iterate loaded, listed buffers whose path is under `prefix`. Cheap, but only
---sees buffers already open in this session.
---@see scan_tree
---@param prefix string
---@param out LanguageSpellIssue[]
---@param cfg LanguageSpellCfg
---@return nil
local function collect_loaded_under(prefix, out, cfg)
  prefix = prefix:gsub("[/\\]+$", "")
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
      local bt = api.nvim_get_option_value("buftype", { buf = bufnr })
      local path = api.nvim_buf_get_name(bufnr)
      if bt == "" and path ~= "" and path:sub(1, #prefix) == prefix then
        local ext = path:match("%.([^.]+)$")
        if not ext or TEXT_EXT[ext] then
          collect_buf_range(bufnr, 1, api.nvim_buf_line_count(bufnr), out, cfg)
        end
      end
    end
  end
end

-- ── Recursive disk tree scan (async, chunked) ───────────────────────────────
-- The native cwd/path fallback above only sees already-loaded buffers. When no
-- external CLI provider (typos/cspell/codespell) is configured/available,
-- `scan_tree` instead walks the actual directory tree on disk — every matching
-- file is checked, not just the ones currently open — reading unopened files
-- from disk and preferring live buffer content for files that are open (so
-- unsaved edits are reflected). Chunked via `vim.schedule` so large trees
-- don't block the editor.

---Directory names never descended into.
---@type table<string, true>
local TREE_IGNORE_DIR = {
  [".git"] = true,
  node_modules = true,
  [".venv"] = true,
  venv = true,
  dist = true,
  build = true,
  target = true,
  [".cache"] = true,
  __pycache__ = true,
}

---Files above this size are skipped before reading (cheap pre-filter; the
---`max_file_lines` config cap still applies after read for smaller files).
local TREE_MAX_BYTES = 5 * 1024 * 1024

---@internal
---Gather text files (by `TEXT_EXT`, skipping vendor dirs) under `dir`.
---@param dir string
---@return string[] absolute paths
local function gather_tree_files(dir)
  ---@type string[]
  local out = {}
  local ok, err = pcall(function()
    for name, typ in
      vim.fs.dir(dir, {
        depth = 24,
        -- never enter an ignored folder: walking node_modules/.git and dropping the entries
        -- afterwards cost 600 ms on a 7 000-file vault (measured 2026-11-17)
        skip = function(sub)
          return not TREE_IGNORE_DIR[sub:match("[^/]+$") or sub]
        end,
      })
    do
      if typ == "file" then
        local skip = false
        for seg in name:gmatch("[^/\\]+") do
          if TREE_IGNORE_DIR[seg] then
            skip = true
            break
          end
        end
        local ext = name:match("%.([^.\\/]+)$")
        if not skip and ext and TEXT_EXT[ext:lower()] then
          out[#out + 1] = fn.fnamemodify(dir .. "/" .. name, ":p")
        end
      end
    end
  end)
  if not ok then
    -- A failure mid-walk (permissions, a vanishing entry, …) would otherwise
    -- yield a silently truncated file list indistinguishable from "this is
    -- the whole tree".
    notify.warn(
      ("directory walk under %s stopped early (%s); results may be incomplete"):format(
        dir,
        tostring(err)
      )
    )
  end
  return out
end

---Files scanned per event-loop tick during a disk tree walk.
local TREE_CHUNK = 20

---@internal
---Recursively scan every text file under `dir` (not just open buffers).
---Cancellable; delivers the full issue list via `cb` when done.
---@param dir string
---@param cfg LanguageSpellCfg
---@param cb fun(issues: LanguageSpellIssue[])
---@return Language.Job
local function scan_tree_async(dir, cfg, cb)
  local files = gather_tree_files(dir)
  ---@type LanguageSpellIssue[]
  local out = {}
  local i = 0
  local cancelled = false
  local max_lines = cfg.max_file_lines

  local function step()
    if cancelled then
      return
    end
    local last = math.min(i + TREE_CHUNK, #files)
    for idx = i + 1, last do
      local abs = files[idx]
      local buf = fn.bufnr(abs)
      if buf > 0 and api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) then
        -- Open in this session: use live content (reflects unsaved edits).
        if scannable(buf, cfg) then
          collect_buf_range(buf, 1, api.nvim_buf_line_count(buf), out, cfg)
        end
      else
        -- Not open: read from disk (size-capped, then line-count-capped).
        local size = fn.getfsize(abs)
        if size >= 0 and size <= TREE_MAX_BYTES then
          local ok, lines = pcall(fn.readfile, abs)
          if ok and type(lines) == "table" and (not max_lines or #lines <= max_lines) then
            scan_lines(lines, 1, nil, abs, out, cfg, nil)
          end
        end
      end
    end
    i = last
    if i >= #files then
      cb(out)
    else
      vim.schedule(step)
    end
  end

  step()

  ---@type Language.Job
  return {
    cancel = function()
      cancelled = true
    end,
  }
end

---Async cwd/path scan: a real recursive disk walk, used as the native
---fallback in `collect.gather` when no external CLI spell provider is
---available. For a `path` that points at a single file, reads just that file.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@param cb fun(issues: LanguageSpellIssue[])
---@return Language.Job|nil
function M.scan_tree(scope, cfg, cb)
  if scope.kind == "path" and scope.path and fn.isdirectory(scope.path) == 0 then
    ---@type LanguageSpellIssue[]
    local out = {}
    local ok, err = collect_file(scope.path, out, cfg)
    if not ok then
      -- Otherwise indistinguishable from "this path is clean": the scope
      -- was never actually opened.
      notify.warn(err)
    end
    cb(out)
    return nil
  end
  local dir = (scope.kind == "path" and scope.path) or fn.getcwd()
  return scan_tree_async(dir, cfg, cb)
end

---Scan the given scope and return all native spell issues.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
function M.scan_scope(scope, cfg)
  ---@type LanguageSpellIssue[]
  local out = {}
  local kind = scope.kind

  if kind == "buffer" then
    local b = scope.bufnr or api.nvim_get_current_buf()
    collect_buf_range(b, 1, api.nvim_buf_line_count(b), out, cfg)
  elseif kind == "visible" or kind == "selection" then
    local b = scope.bufnr or api.nvim_get_current_buf()
    local r = scope.range or { s = 1, e = api.nvim_buf_line_count(b) }
    collect_buf_range(b, r.s, r.e, out, cfg)
  elseif kind == "cwd" then
    collect_loaded_under(fn.getcwd(), out, cfg)
  elseif kind == "path" then
    local path = scope.path or fn.getcwd()
    if fn.isdirectory(path) == 1 then
      collect_loaded_under(path, out, cfg)
    else
      collect_file(path, out, cfg)
    end
  end

  return out
end

---Native suggestions for an issue's word via `spellsuggest`.
---@param issue LanguageSpellIssue
---@return string[]
function M.suggest(issue)
  if type(issue) ~= "table" or type(issue.word) ~= "string" then
    return {}
  end
  local ok, res = pcall(fn.spellsuggest, issue.word, 10)
  if ok and type(res) == "table" then
    return res
  end
  return {}
end

return M
