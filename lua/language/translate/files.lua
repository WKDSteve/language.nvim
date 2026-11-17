---@module 'language.translate.files'
---@brief Multi-file translation for cwd/path scopes.
---@description
--- Gathers translatable files under a directory, lets the user pick several via
--- the kit multi-select chooser (<Tab> to toggle), then translates each file
--- sequentially (progress feedback) and writes the result according to the
--- output mode:
---   "suffix"  → sibling file  name.<TARGET>.ext  (default, non-destructive)
---   "replace" → overwrite the file in place (asks for confirmation first)
---   "buffers" → open each translation in a scratch buffer (no disk write)
---
--- Note: `--nocode` and per-range code-skipping apply to buffer/selection
--- translation only; whole files are translated as one block here, except
--- subtitle files (`.srt`, `.vtt`), where only the cue text is sent.

require("language.@types")
require("language.translate.@types")

local api = vim.api
local fn = vim.fn

local notify = require("lib.nvim.notify").create("[language.translate]")

local M = {}

---Directory names never descended into.
---@type table<string, true>
local IGNORE_DIR = {
  [".git"] = true,
  node_modules = true,
  [".venv"] = true,
  venv = true,
  dist = true,
  build = true,
  target = true,
  [".cache"] = true,
  ["__pycache__"] = true,
}

---@internal
---@return LanguageTranslateCfg
local function cfg()
  return require("language.config").get().translate
end

---Gather translatable files (by extension + size) under `dir`. Public for
---testing.
---
---A walk that fails partway (permissions, a vanishing entry, …) would
---otherwise yield a silently truncated file list indistinguishable from
---"this is every matching file" (ERR-11) -- same failure already fixed in
---spell/providers/native.lua's `gather_tree_files`, same fix here.
---@param dir string
---@param c LanguageTranslateCfg
---@return { rel: string, abs: string }[]
function M.gather(dir, c)
  local exts = {}
  for _, e in ipairs((c.files and c.files.extensions) or {}) do
    exts[e:lower()] = true
  end
  local max_bytes = ((c.files and c.files.max_kb) or 512) * 1024

  ---@type { rel: string, abs: string }[]
  local out = {}
  local ok, err = pcall(function()
    for name, typ in
      vim.fs.dir(dir, {
        depth = 24,
        -- never enter an ignored folder: walking node_modules/.git and dropping the entries
        -- afterwards cost 600 ms on a 7 000-file vault (measured 2026-11-17)
        skip = function(sub)
          return not IGNORE_DIR[sub:match("[^/]+$") or sub]
        end,
      })
    do
      if typ == "file" then
        local skip = false
        for seg in name:gmatch("[^/\\]+") do
          if IGNORE_DIR[seg] then
            skip = true
            break
          end
        end
        local ext = name:match("%.([^.\\/]+)$")
        if not skip and ext and exts[ext:lower()] then
          local abs = fn.fnamemodify(dir .. "/" .. name, ":p")
          local sz = fn.getfsize(abs)
          if sz >= 0 and sz <= max_bytes then
            out[#out + 1] = { rel = name:gsub("\\", "/"), abs = abs }
          end
        end
      end
    end
  end)
  if not ok then
    notify.warn(
      ("directory walk under %s stopped early (%s); the file list may be incomplete"):format(
        dir,
        tostring(err)
      )
    )
  end
  table.sort(out, function(a, b)
    return a.rel < b.rel
  end)
  return out
end

---@internal
---Sibling path with the target language inserted before the extension.
---@param abs string
---@param target string
---@return string
local function suffix_path(abs, target)
  local dir = fn.fnamemodify(abs, ":h")
  local stem = fn.fnamemodify(abs, ":t:r")
  local ext = fn.fnamemodify(abs, ":e")
  return dir .. "/" .. stem .. "." .. target .. (ext ~= "" and ("." .. ext) or "")
end

---@internal
---Deliver one file's translation according to `mode`.
---@param mode string
---@param abs string
---@param original string[]  content read before the request was sent; used to
---                           detect a concurrent edit in `replace` mode
---@param result string[]
---@param target string
---@return string|nil written_path, integer|nil bufnr, string|nil err
local function deliver(mode, abs, original, result, target)
  if mode == "buffers" then
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(buf, 0, -1, false, result)
    pcall(api.nvim_buf_set_name, buf, suffix_path(abs, target))
    local ft = vim.filetype.match({ filename = abs })
    if ft then
      vim.bo[buf].filetype = ft
    end
    return nil, buf, nil
  elseif mode == "replace" then
    -- Re-verify against the current on-disk content immediately before
    -- overwriting: the request was a network round trip, so the file may
    -- have changed on disk since `original` was read for it.
    local ok_read, current = pcall(fn.readfile, abs)
    if not ok_read or type(current) ~= "table" then
      return nil, nil, "cannot re-read before write: " .. abs
    end
    if #current ~= #original or table.concat(current, "\n") ~= table.concat(original, "\n") then
      return nil, nil, "skipped, file changed on disk during translation: " .. abs
    end
    local ok_write, code = pcall(fn.writefile, result, abs)
    if not ok_write or code == -1 then
      return nil, nil, "failed to write " .. abs
    end
    return abs, nil, nil
  else -- suffix
    local dst = suffix_path(abs, target)
    local ok_write, code = pcall(fn.writefile, result, dst)
    if not ok_write or code == -1 then
      return nil, nil, "failed to write " .. dst
    end
    return dst, nil, nil
  end
end

---Translate the picked files sequentially, then finish. Public for testing.
---@param provider LanguageTranslateProvider
---@param picked { rel: string, abs: string }[]
---@param target string
---@param mode string
---@param on_done fun()|nil
---@return nil
function M.process(provider, picked, target, mode, on_done)
  local prog = require("lib.nvim.progress").create({ title = "[language]" })
  local c = cfg()
  local i = 0
  local done_count = 0
  local first_buf_shown = false

  local function step()
    i = i + 1
    if i > #picked then
      prog:finish(("translated %d/%d file(s) → %s"):format(done_count, #picked, target))
      if on_done then
        on_done()
      end
      return
    end
    prog:update({ text = "translating " .. picked[i].rel, current = i, total = #picked })

    local ok, lines = pcall(fn.readfile, picked[i].abs)
    if not ok or type(lines) ~= "table" then
      notify.error(("cannot read %s, skipped"):format(picked[i].rel))
      vim.schedule(step)
      return
    end

    -- One file's failure -- including a provider that throws -- fails that file
    -- only: the progress display still advances and the rest keep running.
    local settled = false
    local function on_result(ok2, result)
      if settled then
        return
      end
      settled = true
      if ok2 and type(result) == "table" then
        local written, buf, derr = deliver(mode, picked[i].abs, lines, result, target)
        if derr then
          notify.error(("translate write failed: %s (%s)"):format(picked[i].rel, derr))
        else
          done_count = done_count + 1
          if mode == "buffers" and buf and not first_buf_shown then
            -- Show the first translated buffer; the rest stay listed.
            pcall(api.nvim_set_current_buf, buf)
            first_buf_shown = true
          end
          require("language.translate.history").record({
            input = { picked[i].rel },
            output = written and { written } or result,
            target = target,
          })
        end
      else
        notify.error(("translate failed: %s (%s)"):format(picked[i].rel, tostring(result)))
      end
      vim.schedule(step)
    end

    local kind = require("language.translate.subtitle").detect(picked[i].abs, nil, lines)
    local started, thrown
    if kind then
      started, thrown = pcall(
        require("language.translate.subtitle").translate,
        provider,
        lines,
        kind,
        target,
        c,
        function(ok3, result, info)
          if ok3 and info and info.kept > 0 then
            notify.warn(
              ("%s: %d subtitle cue(s) kept in the source language (the engine broke a tag)"):format(
                picked[i].rel,
                info.kept
              )
            )
          end
          on_result(ok3, result)
        end
      )
    else
      started, thrown = pcall(provider.translate, lines, target, nil, c, on_result)
    end
    if not started then
      on_result(false, thrown)
    end
  end

  step()
end

---Map a `cwd`/`path` scope to what `M.run` translates: the directory to
---pick files from, or the one file to translate. A path that is neither an
---existing directory nor a readable file yields `nil` and the reason, so the
---caller can say so instead of guessing.
---@param scope LanguageScope
---@return { dir?: string, file?: string }|nil target, string|nil err
function M.target(scope)
  if scope.kind == "cwd" then
    return { dir = fn.getcwd() }
  end
  local path = scope.path
  if type(path) ~= "string" or path == "" then
    return nil, "path= needs a file or directory"
  end
  if fn.isdirectory(path) == 1 then
    return { dir = path }
  end
  if fn.filereadable(path) == 1 then
    return { file = path }
  end
  return nil, "no such file or directory: " .. path
end

---Run multi-file translation under `opts.dir`, or translate the one file
---`opts.file` the same way without a picker.
---@param target string
---@param opts { dir?: string, file?: string, mode?: string }
---@return nil
function M.run(target, opts)
  if type(target) ~= "string" or target == "" then
    notify.warn("Please specify a target language, e.g. :Translate DE cwd")
    return
  end
  local c = cfg()
  local provider, err = require("language.translate.providers.registry").resolve(c)
  if not provider then
    notify.error(err or "no translate engine available")
    return
  end

  if opts.file then
    local abs = fn.fnamemodify(opts.file, ":p")
    if fn.filereadable(abs) ~= 1 then
      notify.error("no such file: " .. opts.file)
      return
    end
    local fmode = opts.mode or (c.files and c.files.output) or "suffix"
    if fmode == "replace" then
      local ans = fn.confirm(
        ("Overwrite %s in place with the %s translation?"):format(fn.fnamemodify(abs, ":t"), target),
        "&Yes\n&No",
        2
      )
      if ans ~= 1 then
        notify.info("cancelled")
        return
      end
    end
    M.process(provider, { { rel = fn.fnamemodify(abs, ":~:."), abs = abs } }, target, fmode)
    return
  end

  local dir = fn.fnamemodify(opts.dir or fn.getcwd(), ":p")
  local files = M.gather(dir, c)
  if #files == 0 then
    notify.info("No translatable files under " .. dir)
    return
  end

  local mode = opts.mode or (c.files and c.files.output) or "suffix"

  local items = {}
  for idx, f in ipairs(files) do
    items[idx] = f.rel
  end

  require("ui.kit").select({
    items = items,
    multi = true,
    title = ("Translate → %s  (<Tab> select, <CR> confirm) [%s]"):format(target, mode),
    on_select = function(_, idxs)
      ---@type { rel: string, abs: string }[]
      local picked = {}
      for _, i in ipairs(idxs or {}) do
        if files[i] then
          picked[#picked + 1] = files[i]
        end
      end
      if #picked == 0 then
        return
      end
      if mode == "replace" then
        local ans = fn.confirm(
          ("Overwrite %d file(s) in place with the %s translation?"):format(#picked, target),
          "&Yes\n&No",
          2
        )
        if ans ~= 1 then
          notify.info("cancelled")
          return
        end
      end
      M.process(provider, picked, target, mode)
    end,
  })
end

return M
