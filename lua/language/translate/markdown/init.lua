---@module 'language.translate.markdown'
---@brief `translate_markdown(lines, opts, cb)`: a Markdown-safe, line-true translation.
---@description
--- Translates a whole Markdown document through the configured engine and
--- returns exactly as many lines as it got: `#out == #in`, always.
---
---   segment   cut into literal lines (front matter, fences, HTML, reference
---             definitions, ...) and units (headings, paragraphs, list items,
---             quotes, table cells)
---   mask      inline code, link targets, autolinks, ... become `{n}`
---   cache     a unit seen before (same text, target, source, engine, model)
---             is not sent again
---   batch     the remaining units go to the engine in requests of at most
---             `max_chars` / `max_units`, `concurrency` of them at a time
---   validate  every answer is checked (placeholders complete, plausible
---             length); one retry; then the ORIGINAL unit stays
---   reflow    each translation is wrapped onto the line count of its source,
---             never breaking in front of a block-start token
---   anchors   `](#old-slug)` is rewritten to the slug of the translated heading
---
--- All of that is CPU work in plain Lua. Past a size (see SLICE_MIN_LINES / SLICE_MIN_BYTES / SLICE_COST_LIMIT) it
--- runs in slices (`slice.lua`): the work is a coroutine that hands the control back to the event
--- loop at the interruption points, so a big document never blocks the editor for long. Only the
--- timing changes, not the result.
---
--- A unit that could not be translated is never an error of the call: it stays
--- German (original) and is counted in `info.failed`. The call itself fails only
--- when it cannot start (no engine, bad arguments), when it is cancelled, or
--- when its token went stale.
---
--- Every callback runs on the main loop, never before `translate_markdown`
--- has returned. `cb` runs exactly once. `on_unit` is called once per changed block, `done` counts
--- 1..total in the order of the calls, a block that points at a heading is reported after the
--- anchor map exists (not with `cache_only`: a block that links to a heading that is not in the
--- cache is returned translated, but gets no event), and the blocks that waited for the map come
--- before the block of the heading that completed it; the order of the other blocks is the order in which their work finished,
--- which can differ between a sliced and an unsliced run (the gaps of a slice let answers of the
--- engine arrive in between), and so can the order of `info.errors`.

require("language.translate.@types")
require("language.translate.markdown.@types")

local anchors = require("language.translate.markdown.anchors")
local cache = require("language.translate.markdown.cache")
local mask = require("language.translate.markdown.mask")
local reflow = require("language.translate.markdown.reflow")
local segment = require("language.translate.markdown.segment")
local slice = require("language.translate.markdown.slice")

local M = {}

M.cache = cache

local DEFAULT_MAX_UNITS = 40
---A document is translated in one go when its estimated work stays under these three limits: fewer
---lines, fewer bytes and a smaller estimated cost than these. Neither lines nor bytes tell the
---work: it follows the units (a table cell is a unit of its own), so the estimate weighs lines,
---bytes and pipes (each one can be a cell: an upper bound that is cheap to take, a plain `find`).
---The weights err on the high side; what stays under the limit is about 30 ms of work, and the
---callback of such a document arrives in the first turn of the loop. The measurements the weights
---are fitted to are in docs/FEATURES/TRANSLATE.md ("Big documents").
local SLICE_MIN_LINES = 2000
local SLICE_MIN_BYTES = 64 * 1024
local SLICE_COST_LIMIT = 30000
local SLICE_COST_LINE, SLICE_COST_BYTE, SLICE_COST_PIPE = 12, 0.375, 3
---An answer for texts that occur this often in the document (all its entries together) is booked
---in slices, too (the loop over its units reports each of them).
local SLICE_ANSWER_UNITS = 256
---An answer of more bytes than this (all its lines together) is validated and booked in a
---coroutine of its own: the check of the placeholders of ONE unit of a megabyte is tens of ms.
local SLICE_ANSWER_BYTES = 64 * 1024
local MAX_ERRORS = 5
local ABORT_AFTER = 3

---@internal
---@param v any
---@param default integer
---@param lo integer
---@param hi integer
---@return integer
local function int(v, default, lo, hi)
  if type(v) ~= "number" or v ~= v then
    return default
  end
  return math.max(lo, math.min(hi, math.floor(v)))
end

---@internal
---@param tr table
---@param opts table
---@return table
local function settings(tr, opts)
  local m = type(tr.markdown) == "table" and tr.markdown or {}
  local keep = {}
  local function add(list)
    if type(list) == "table" then
      for _, w in ipairs(list) do
        keep[#keep + 1] = w
      end
    end
  end
  add(m.keep)
  add(opts.keep)
  return {
    concurrency = int(opts.concurrency, int(m.concurrency, 3, 1, 16), 1, 16),
    max_chars = int(opts.max_chars, int(m.max_chars, 3000, 200, 100000), 200, 100000),
    max_units = int(opts.max_units, DEFAULT_MAX_UNITS, 1, 50),
    disk = m.disk_cache ~= false,
    cache_max_kb = int(m.cache_max_kb, 2048, 16, 102400),
    cache_dir = type(m.cache_dir) == "string" and m.cache_dir or nil,
    keep = keep,
  }
end

---@internal
---Does `text` look like a plausible translation of `orig` (both masked)?
---@param orig string
---@param text string
---@return boolean
local function plausible(orig, text)
  local a, b = #orig, #text
  if b == 0 then
    return false
  end
  if a >= 20 then
    return b >= a * 0.12 and b <= a * 6
  end
  return b <= a * 8 + 40
end

-- What would turn translated prose into a link, an image or markup the source did not
-- have: an inline link or image, a reference link, an HTML tag, an address with a scheme,
-- a `www.` address or an e-mail address (the last two are links to the previewer, too). The
-- e-mail pattern is as wide as the previewer's autolinker: `.`, `+`, `-` and `_` in the local
-- part (`_@x.example`, `.@x.example`), `_` in the first label of the domain (`a@x_y.example`).
-- Each with a literal that every match contains: a text without it has no match, and a plain `find`
-- says so far faster than the pattern (a megabyte without an `@`).
local NEW_SYNTAX = {
  { "%]%(", "](" },
  { "%]%[", "][" },
  { "<%a", "<" },
  { "</", "</" },
  { "<!", "<!" },
  { "://", "://" },
  { "www%.", "www." },
  { "[%w%._%+%-]@[%w_%-]+%.%w", "@" },
}

---@internal
---Trailing punctuation that belongs to the sentence, not to an address.
---@param s string
---@return string
local function trim_address(s)
  return (s:gsub("[%.,;:!?%)%]}'\"*_~]+$", ""))
end

---@internal
---The spelling of an address that does not change what it points at: the scheme and the host in lower
---case, the hex digits of a `%XX` escape in upper case, a lone trailing `/` dropped. A translation may
---re-case or re-slash these without anything having been swapped; the path stays as it is, it is case
---sensitive.
---@param a string
---@return string
local function normalize_address(a)
  a = a:gsub("%%(%x%x)", function(h)
    return "%" .. h:upper()
  end)
  local scheme, host, rest = a:match("^(%a[%w%+%.%-]*://)([^/?#]*)(.*)$")
  if not scheme then
    if not a:find("^www%.") then
      local local_part, domain = a:match("^([^@]+@)([^@]+)$")
      if local_part then
        return local_part .. domain:lower()
      end
    end
    host, rest = a:match("^([^/?#]*)(.*)$")
    scheme = ""
  end
  if rest == "/" then
    rest = ""
  end
  return scheme:lower() .. host:lower() .. rest
end

local ADDRESS_CHARS = "[%w%-%._~:/%?#%[%]@!$&'()*+,;=%%]"

---@internal
---Cut the addresses (with a scheme, `www.` form or e-mail form) out of `s` and count them.
---An address is an ASCII run: text of a CJK target that follows it without a blank is not
---part of it, so a translation that moves the sentence around does not look like a new address.
---Nothing runs for a text without `://`, `www.` or `@`. Every scan starts at a marker found with a
---plain `find` and runs outwards from there with an anchored match: an unanchored pattern would
---retry from every byte of a long run of letters (30000 of them took 8 s).
---@param s string
---@param tick fun()
---@return table<string, integer>|nil counts
local function addresses(s, tick)
  local has_scheme = s:find("://", 1, true)
  local has_www = s:find("www.", 1, true)
  local has_at = s:find("@", 1, true)
  if not (has_scheme or has_www or has_at) then
    return nil
  end
  local counts = {}
  local function add(a)
    a = trim_address(a)
    if a ~= "" then
      a = normalize_address(a)
      counts[a] = (counts[a] or 0) + 1
    end
  end

  if has_scheme then
    local init = 1
    while true do
      tick()
      local at = s:find("://", init, true)
      if not at then
        break
      end
      -- the scheme: letters, digits and `+.-` back from the marker (at most 32 bytes), starting with a letter
      local a = at
      while a > init and at - a < 32 and s:sub(a - 1, a - 1):match("[%w%+%.%-]") do
        a = a - 1
      end
      while a < at and not s:sub(a, a):match("%a") do
        a = a + 1
      end
      local tail = s:match("^" .. ADDRESS_CHARS .. "+", at + 3)
      if a < at and tail then
        add(s:sub(a, at + 2) .. tail)
        init = at + 3 + #tail
      else
        init = at + 3
      end
    end
  end

  if has_www then
    local init = 1
    while true do
      tick()
      local at = s:find("www.", init, true)
      if not at then
        break
      end
      local word = s:match("^www%.[%w%-]+%." .. ADDRESS_CHARS .. "*", at)
      if word then
        add(word)
        init = at + #word
      else
        init = at + 4
      end
    end
  end

  if has_at then
    local init = 1
    while true do
      tick()
      local at = s:find("@", init, true)
      if not at then
        break
      end
      -- the local part back from the `@` (at most 256 bytes), the domain forward
      local a = at
      while a > init and at - a <= 256 and s:sub(a - 1, a - 1):match("[%w%._%+%-]") do
        a = a - 1
      end
      local domain = s:match("^[%w_%-]+%.[%w%.%-]*%w", at + 1)
      if a < at and domain then
        add(s:sub(a, at) .. domain)
        init = at + 1 + #domain
      else
        init = at + 1
      end
    end
  end
  return counts
end

---@internal
---Does `text` carry link or HTML syntax that the masked source `orig` does not? The
---destinations of the source are placeholders, so anything of this kind left over is
---new: an engine (a language model, with a document that argues with it) must not be
---able to add a link, a tracking image or a tag to the output.
---
---The patterns are counted; the addresses are compared themselves: one the mask leaves
---alone is in the source, so an engine may keep it but not swap it for another.
---@param orig string
---@param text string
---@param tick? fun()  -- an interruption point of the slicer (an answer of a megabyte)
---@return boolean
local function adds_syntax(orig, text, tick)
  local scan = tick or function() end
  tick = slice.every(tick)
  ---The matches of `pat` in `str`, counted as `gsub` counts them, but with a `find` per match:
  ---no copy of the text, and the slicer may yield between two of them (and before each scan: a
  ---pattern that is not there is one `find` over the whole text).
  local function count(str, pat, lit)
    scan()
    if not str:find(lit, 1, true) then
      return 0
    end
    local n, init = 0, 1
    while true do
      tick()
      local _, e = str:find(pat, init)
      if not e then
        return n
      end
      n, init = n + 1, e + 1
    end
  end
  for _, syn in ipairs(NEW_SYNTAX) do
    if count(text, syn[1], syn[2]) > count(orig, syn[1], syn[2]) then
      return true
    end
  end
  local mine = addresses(text, tick)
  if mine then
    local known = addresses(orig, tick) or {}
    for address, n in pairs(mine) do
      if n > (known[address] or 0) then
        return true
      end
    end
  end
  return false
end

---@internal
---Number of unescaped pipes in `s`.
---@param s string
---@return integer
local function pipe_count(s)
  local n, i = 0, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c == "|" then
      n = n + 1
    end
    i = i + 1
  end
  return n
end

---@internal
---Would `text` (the translation of the table cell `orig`) change the shape of
---the row: a pipe of its own, or a backslash that escapes the pipe behind it?
---@param orig string
---@param text string
---@return boolean
local function cell_breaks(orig, text)
  local bs = 0 -- trailing backslashes
  while bs < #text and text:byte(#text - bs) == 92 do
    bs = bs + 1
  end
  return pipe_count(text) ~= pipe_count(orig) or bs % 2 == 1
end

---@internal
---White space as `%s` sees it (ASCII).
---@param b integer|nil
---@return boolean
local function is_ws(b)
  return b ~= nil and (b == 32 or (b >= 9 and b <= 13))
end

---@internal
---Does the last white-space-free word of `line` hold an address with a scheme? A byte scan
---back to the white space and a search in that word only: `match("https?://[^%s]*$")` reads to
---the end of the word from every `http` in it, run^2 on a long word of them.
---@param line string
---@return boolean
local function ends_in_address(line)
  local k = #line
  while k > 0 and not is_ws(line:byte(k)) do
    k = k - 1
  end
  return line:find("https?://", k + 1) ~= nil
end

---@internal
---One line: every run of white space around a line break becomes one space, the ends are
---trimmed. A byte scan, not `%s*[\r\n]+%s*` and `%s+$`, which are quadratic on a long run
---of white space.
---@param text string
---@return string
local function flatten(text)
  local out, n, pos = {}, 0, 1
  while true do
    local p = text:find("[\r\n]", pos)
    if not p then
      n = n + 1
      out[n] = text:sub(pos)
      break
    end
    local l = p - 1
    while l >= pos and is_ws(text:byte(l)) do
      l = l - 1
    end
    local r = p + 1
    while is_ws(text:byte(r)) do
      r = r + 1
    end
    out[n + 1], out[n + 2] = text:sub(pos, l), " "
    n = n + 2
    pos = r
  end
  text = table.concat(out)
  local a, z = 1, #text
  while is_ws(text:byte(a)) do
    a = a + 1
  end
  while z >= a and is_ws(text:byte(z)) do
    z = z - 1
  end
  return text:sub(a, z)
end

---@internal
---Is the work on `lines` too small to be worth slicing (see SLICE_MIN_LINES / SLICE_MIN_BYTES /
---SLICE_COST_LIMIT)? One pass, ending at the first limit that is reached.
---@param lines string[]
---@return boolean
local function is_small(lines)
  if #lines >= SLICE_MIN_LINES then
    return false
  end
  local bytes, pipes = 0, 0
  for i = 1, #lines do
    local line = lines[i]
    bytes = bytes + #line
    local at = line:find("|", 1, true)
    while at do
      pipes = pipes + 1
      at = line:find("|", at + 1, true)
    end
    if
      bytes >= SLICE_MIN_BYTES
      or i * SLICE_COST_LINE + bytes * SLICE_COST_BYTE + pipes * SLICE_COST_PIPE
        >= SLICE_COST_LIMIT
    then
      return false
    end
  end
  return true
end

---Translate a Markdown document.
---@param lines string[]
---@param opts LanguageMdTranslateOpts
---@param cb LanguageMdTranslateCb
---@return { cancel: fun() } handle
function M.translate_markdown(lines, opts, cb)
  opts = opts or {}
  local finished = false
  ---@type table<table, boolean>
  local jobs = {}

  local function finish(ok, res, info)
    if finished then
      return
    end
    finished = true
    for job in pairs(jobs) do
      pcall(job.cancel)
    end
    jobs = {}
    cb(ok, res, info)
  end

  local handle = {
    cancel = function()
      finish(false, "cancelled")
    end,
  }

  if type(cb) ~= "function" then
    error("translate_markdown: cb must be a function", 2)
  end
  local bad
  if type(lines) ~= "table" then
    bad = "lines must be a list of strings"
  else
    for i = 1, #lines do
      if type(lines[i]) ~= "string" then
        bad = ("lines[%d] is not a string"):format(i)
        break
      end
    end
  end
  if not bad and (type(opts.target) ~= "string" or opts.target == "") then
    bad = "opts.target (the target language) is required"
  end
  if bad then
    vim.schedule(function()
      finish(false, bad)
    end)
    return handle
  end

  local function stale()
    local t = opts.token
    if type(t) ~= "table" then
      return false
    end
    if t.cancelled then
      return true
    end
    if type(t.current) == "function" then
      local ok, v = pcall(t.current)
      return ok and v ~= t.generation
    end
    return false
  end

  ---Something threw, in a coroutine of the slicer or in the callback of an answer: the call ends
  ---with `cb(false, "translate_markdown: ...")`, once. When `cb` has run already, there is nothing
  ---left to report it to but the user: this is `cb` (or `on_unit`'s caller) throwing.
  ---@param err any
  local function crashed(err)
    if finished then
      vim.notify("translate_markdown: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    finish(false, "translate_markdown: " .. tostring(err))
  end

  ---A slicer for the CPU-bound phases (segment, mask, cache pass, finalisation): a document of
  ---100 000 lines would keep the event loop busy for seconds. `stop` is asked before each slice
  ---(also the first one): a cancelled or stale call is not continued (and a stale one is reported
  ---once). An explicit `slice_ms` wins over the size of the document.
  local sl = slice.new({
    budget_ms = type(opts.slice_ms) == "number" and opts.slice_ms
      or (is_small(lines) and math.huge or nil),
    stop = function()
      if finished then
        return true
      end
      if stale() then
        finish(false, "stale")
        return true
      end
      return false
    end,
    on_error = crashed,
  })
  local tick = sl.tick

  local function run()
    local t0 = vim.uv.hrtime()
    if stale() then
      finish(false, "stale")
      return
    end

    local tr = opts.cfg or require("language.config").get().translate or {}
    if tr.run_id == nil then
      -- one run per document: the engine's budget (the ai bulk label) holds for all of its calls
      tr =
        vim.tbl_extend("force", tr, { run_id = require("language.translate.chunk").new_run_id() })
    end
    local st = settings(tr, opts)

    local provider, perr = opts.provider, nil
    if not provider then
      local reg = require("language.translate.providers.registry")
      local rcfg = tr
      if opts.engine then
        rcfg = vim.tbl_extend("force", tr, { engine = opts.engine, fallback = {} })
      end
      provider, perr = reg.resolve(rcfg, { failover = false })
    end
    if not provider and not opts.cache_only then
      finish(false, perr or "no available translate engine")
      return
    end
    local engine = provider and provider.name or opts.engine or tr.engine or "?"
    local target, source = opts.target, opts.source

    local use_cache = opts.cache ~= false

    ---The model part of the cache key: `opts.model`, plus what the engine says
    ---about itself (`cache_id`: provider, model, prompt version of the `ai`
    ---engine). Asked again at write time, since an answer may have named the
    ---model that "default" turned out to be.
    ---@return string|nil
    local function cache_model()
      local id = provider and type(provider.cache_id) == "function" and provider.cache_id(tr)
      if type(id) ~= "string" or id == "" then
        return opts.model
      end
      return opts.model and (opts.model .. "|" .. id) or id
    end
    if use_cache then
      cache.configure({ disk = st.disk, max_kb = st.cache_max_kb, dir = st.cache_dir })
    end

    local seg = segment.segment(lines, tick)
    local units = seg.units

    ---@class LanguageMdUnitState
    ---@field masked string
    ---@field mk LanguageMdMask
    ---@field anchor boolean
    ---@field tr string|nil
    ---@field status string|nil
    ---@field reflow_failed boolean|string|nil
    ---@field counted boolean|nil
    ---@field entry table|nil
    ---@type LanguageMdUnitState[]
    local ust = {}
    local info = {
      units = #units,
      translated = 0,
      cached = 0,
      failed = 0,
      skipped = 0,
      pending = 0,
      reflow_failed = 0,
      requests = 0,
      retries = 0,
      anchors_changed = 0,
      anchor_collisions = 0,
      errors = {},
      ms = 0,
      slices = 0,
    }

    ---@type table<string, table>
    local entries = {}
    ---@type table[]
    local todo = {}
    local unit_block = {}
    for bi, blk in ipairs(seg.blocks) do
      for _, id in ipairs(blk.units) do
        unit_block[id] = bi
      end
      tick()
    end
    local bstate = {}
    for bi = 1, #seg.blocks do
      bstate[bi] = { pending = 0, changed = false, partial = false, cached_only = true }
      tick()
    end
    local total_blocks, done_blocks = 0, 0
    local is_heading = {}
    for _, id in ipairs(seg.headings) do
      is_heading[id] = true
    end

    for id, u in ipairs(units) do
      tick()
      local masked, mk = mask.mask(u.text, { defs = seg.defs, keep = st.keep, tick = tick })
      local s = { masked = masked, mk = mk, anchor = false }
      local every = slice.every(tick)
      for _, t in ipairs(mk.toks) do
        every()
        if t:match("^%]%(<?#") then
          s.anchor = true
          break
        end
      end
      ust[id] = s
      -- A mask that ran out of budget is not trusted: the unit stays as it is.
      if mask.has_text(masked) and not mk.degraded then
        local e = entries[masked]
        if not e then
          e = { masked = masked, mk = mk, units = {}, heading = false }
          entries[masked] = e
          todo[#todo + 1] = e
        end
        e.units[#e.units + 1] = id
        e.heading = e.heading or is_heading[id] == true
        e.cell = e.cell or u.block == "cell"
        s.entry = e
        local bs = bstate[unit_block[id]]
        bs.pending = bs.pending + 1
      else
        info.skipped = info.skipped + 1
      end
    end
    for _, bs in ipairs(bstate) do
      if bs.pending > 0 then
        total_blocks = total_blocks + 1
      end
      tick()
    end

    -- Anchors ------------------------------------------------------------------
    local map = nil ---@type table<string, string>|nil
    local heading_pending = 0
    for _, id in ipairs(seg.headings) do
      if ust[id].entry then
        heading_pending = heading_pending + 1
      end
      tick()
    end

    local function build_map()
      local old, new = {}, {}
      for i, id in ipairs(seg.headings) do
        old[i] = units[id].text
        local s = ust[id]
        new[i] = s.tr and mask.unmask(s.tr, s.mk, tick) or units[id].text
        tick()
      end
      local built, _, collisions = anchors.build_map(old, new, tick)
      map = built
      info.anchor_collisions = #collisions
      -- two messages at most: a document full of collisions must not push the real failures out of `errors`
      -- (`info.anchor_collisions` has the count)
      for i = 1, math.min(#collisions, 2) do
        if #info.errors < MAX_ERRORS then
          info.errors[#info.errors + 1] = collisions[i]
        end
      end
    end

    ---The map is built in slices, and it can be asked for while a slice of it is waiting for the
    ---next turn of the loop: `then_fn` runs as soon as the map exists (at once when it does).
    local building = false
    ---@type fun()[]
    local waiting = {}

    ---@param then_fn fun()
    local function with_map(then_fn)
      if map then
        then_fn()
        return
      end
      waiting[#waiting + 1] = then_fn
      if building then
        return
      end
      building = true
      sl.run(function()
        build_map()
        building = false
        local list = waiting
        waiting = {}
        for _, fn in ipairs(list) do
          fn()
        end
      end)
    end

    -- Content of a unit / a block -----------------------------------------------

    ---Where an answer can arrive inside the slicer's coroutine (an engine that answers inside
    ---`translate`), its booking runs under `sl.hold`: the ticks below are no-ops there.
    ---@param id integer
    ---@return string[]|nil
    local function unit_content(id)
      local s = ust[id]
      local text, mk = s.tr, s.mk
      if map and s.anchor then
        local toks, changed = {}, false
        local every = slice.every(tick)
        for i, t in ipairs(mk.toks) do
          every()
          local new, c = anchors.rewrite_dest(t, map)
          toks[i], changed = new, changed or c
        end
        if changed then
          mk = { toks = toks, pair = mk.pair }
          -- A unit that stays as it is (nothing to translate, or its translation
          -- failed) still points at a heading whose slug changed: put it together
          -- again from its masked text, with the new targets.
          text = text or s.masked
        end
      end
      if not text then
        return nil
      end
      local u = units[id]
      local function unsafe(word)
        return reflow.starts_block(mask.unmask(word, mk))
      end
      local out, err = reflow.reflow(
        text,
        u.weights,
        { guard_first = u.guard_first, unsafe = unsafe, tick = tick }
      )
      if not out then
        s.reflow_failed = s.tr and (err or true) or nil
        return nil
      end
      for k = 1, #out do
        out[k] = mask.unmask(out[k], mk, tick)
        if k == #out and u.hard_backslash and ends_in_address(out[k]) then
          -- A bare address in front of the break would swallow its backslash.
          s.reflow_failed = s.tr and "the break would join an address" or nil
          return nil
        end
        if reflow.is_table_rule(out[k]) and not reflow.is_table_rule(u.orig[k]) then
          -- This wrap would make a delimiter row of a line of text.
          s.reflow_failed = s.tr and "the wrap would form a table" or nil
          return nil
        end
      end
      return out
    end

    ---@param bi integer
    ---@return string[]
    local function block_lines(bi)
      local blk = seg.blocks[bi]
      local content = {}
      for _, id in ipairs(blk.units) do
        content[id] = unit_content(id)
      end
      return segment.render(seg, content, blk.first, blk.last)
    end

    -- Progress -----------------------------------------------------------------
    local deferred = {}

    local function emit(bi)
      local bs = bstate[bi]
      -- Nothing after `cb`: a cancel from inside an earlier `on_unit` ends the stream.
      if finished or not bs.changed or not opts.on_unit then
        return
      end
      local blk = seg.blocks[bi]
      -- (rendered before it is counted: a block of a megabyte gives way in the middle, and a block
      -- reported in that gap must not overtake it with a higher `done`)
      local out = block_lines(bi)
      if finished then
        return
      end
      done_blocks = done_blocks + 1
      pcall(opts.on_unit, {
        first = blk.first,
        last = blk.last,
        lines = out,
        status = bs.partial and "partial" or (bs.cached_only and "cached" or "translated"),
        done = done_blocks,
        total = total_blocks,
      })
    end

    local function block_ready(bi)
      local needs = false
      for _, id in ipairs(seg.blocks[bi].units) do
        if ust[id].anchor then
          needs = true
        end
      end
      if needs and not map then
        deferred[#deferred + 1] = bi
      else
        emit(bi)
      end
    end

    -- Bookings that go on in slices (the reports of an answer for thousands of identical units, the
    -- blocks that waited for the anchor map): the finalisation waits for them. A gap in the middle
    -- of one would otherwise let it end the call, and the rest of the reports would be lost.
    local resolving = 0
    local finalize_wanted = false
    local finalize ---@type fun()

    local function release()
      resolving = resolving - 1
      if resolving == 0 and finalize_wanted then
        finalize_wanted = false
        finalize()
      end
    end

    ---A unit got its final state (translated, cached or failed).
    ---@param id integer
    ---@param ok boolean
    ---@param from_cache boolean
    local function unit_done(id, ok, from_cache)
      local bi = unit_block[id]
      local bs = bstate[bi]
      if ok then
        bs.changed = true
        if not from_cache then
          bs.cached_only = false
        end
      else
        bs.partial = true
      end
      bs.pending = bs.pending - 1
      local ready = bs.pending == 0
      if is_heading[id] then
        heading_pending = heading_pending - 1
        if heading_pending == 0 then
          -- The last heading: once the map exists, the blocks that waited for it are reported, then
          -- this one (the order of an unsliced run, where the map is there when with_map returns;
          -- a sliced one returns before that).
          resolving = resolving + 1
          with_map(function()
            local list = deferred
            deferred = {}
            for _, d in ipairs(list) do
              emit(d)
              -- (`with_map` runs this inside the slicer's coroutine, where `tick` may yield. If it
              -- ever ran from the callback of an answer instead, the engine's `translate` could
              -- still be on the stack: a synchronous engine answers inside the run coroutine, and
              -- a yield there would suspend the pump in the middle of `pcall(provider.translate)`.)
              tick()
            end
            if ready then
              block_ready(bi)
            end
            release()
          end)
          return
        end
      end
      if ready then
        block_ready(bi)
      end
    end

    if heading_pending == 0 then
      build_map()
    end

    ---@param entry table
    ---@param value string
    ---@param from_cache boolean
    local function resolve_entry(entry, value, from_cache)
      entry.done = true
      local ids = entry.units
      for _, id in ipairs(ids) do
        ust[id].tr = value
        ust[id].status = from_cache and "cached" or "translated"
        if from_cache then
          info.cached = info.cached + 1
        else
          info.translated = info.translated + 1
        end
      end
    end

    ---The cache pass: the units of the entry are booked one by one. It runs in the slicer's
    ---coroutine, nothing of the engine is on the stack: one entry can stand for thousands of
    ---identical units.
    ---@param entry table
    ---@param value string
    local function resolve_cached(entry, value)
      resolve_entry(entry, value, true)
      for _, id in ipairs(entry.units) do
        unit_done(id, true, true)
        tick()
      end
    end

    ---The entries of ONE event of the engine are booked: the valid entries of an answer, or the
    ---entries that failed (an error, an invalid or short answer, the rest given up after repeated
    ---failures). It arrives in a plain callback: the units of all its entries together (each one
    ---may render a block for `on_unit`) are bounded as a whole, not per entry. Up to
    ---SLICE_ANSWER_UNITS they are booked on the spot; more than that is a coroutine of its own,
    ---and the call is not over before it is (see `release`). Other answers may be booked in the
    ---gaps.
    ---@param settled table[]  -- the settled entries (`resolve_entry` / `fail_entries` has run for each)
    ---@param ok boolean       -- translated, or failed
    local function book_units(settled, ok)
      local count = 0
      for _, e in ipairs(settled) do
        count = count + #e.units
      end
      if count <= SLICE_ANSWER_UNITS then
        for _, e in ipairs(settled) do
          for _, id in ipairs(e.units) do
            unit_done(id, ok, false)
          end
        end
        return
      end
      resolving = resolving + 1
      sl.run(function()
        for _, e in ipairs(settled) do
          for _, id in ipairs(e.units) do
            unit_done(id, ok, false)
            tick()
          end
        end
        release()
      end)
    end

    local remaining = 0

    ---The entries could not be translated: they are counted, the error is kept and their units
    ---are booked (as a whole, see `book_units`).
    ---@param settled table[]
    ---@param err string
    local function fail_entries(settled, err)
      for _, entry in ipairs(settled) do
        entry.done = true
        remaining = remaining - 1
        if #info.errors < MAX_ERRORS then
          info.errors[#info.errors + 1] = err
        end
        info.failed = info.failed + #entry.units
      end
      book_units(settled, false)
    end

    ---Validate an answer for `entry`.
    ---@param entry table
    ---@param text any
    ---@param tk? fun()  -- an interruption point, where one may yield (see SLICE_ANSWER_BYTES)
    ---@return string|nil value, string|nil err
    local function validate(entry, text, tk)
      if type(text) ~= "string" then
        return nil, "the engine returned no text"
      end
      text = flatten(mask.normalize(text, tk))
      if text == "" then
        return nil, "the engine returned an empty translation"
      end
      local ok, err = mask.check(text, entry.mk, tk)
      if not ok then
        return nil, err
      end
      if adds_syntax(entry.masked, text, tk) then
        return nil, "the translation adds link or HTML syntax"
      end
      if not plausible(entry.masked, text) then
        return nil, "implausible length of the translation"
      end
      if entry.cell and cell_breaks(entry.masked, text) then
        return nil, "the translation would split or merge table cells"
      end
      return text
    end

    -- Cache pass ---------------------------------------------------------------
    local misses = {}
    local read_model = use_cache and cache_model() or nil
    for _, e in ipairs(todo) do
      tick()
      e.key = use_cache and cache.key(engine, read_model, target, source, e.masked) or nil
      local hit = e.key and cache.get(e.key)
      local value = hit and validate(e, hit, tick)
      if value then
        resolve_cached(e, value)
      else
        misses[#misses + 1] = e
      end
    end

    -- Headings first, so the anchor map is known early; document order inside both groups.
    -- A partition of the (already ordered) list, not a `table.sort`: a comparator is a C boundary
    -- the slicer cannot yield across, and 20 000 entries are a long time in one.
    do
      local heads, rest = {}, {}
      for _, e in ipairs(misses) do
        local into = e.heading and heads or rest
        into[#into + 1] = e
        tick()
      end
      misses = heads
      table.move(rest, 1, #rest, #heads + 1, heads)
    end

    for _, e in ipairs(misses) do
      info.pending = info.pending + #e.units
      tick()
    end

    -- Finalisation ---------------------------------------------------------------
    local function finalize_rest()
      if finished then
        return
      end
      local content = {}
      for id = 1, #units do
        content[id] = unit_content(id)
        if ust[id].reflow_failed and not ust[id].counted then
          ust[id].counted = true
          info.reflow_failed = info.reflow_failed + 1
        end
        tick()
      end
      local out = segment.render(seg, content, nil, nil, tick)
      local amap = map or {}
      for _, L in ipairs(seg.refdefs) do
        local new, changed = anchors.rewrite_refdef(out[L], amap)
        if changed then
          out[L] = new
          info.anchors_changed = info.anchors_changed + 1
        end
        tick()
      end
      for id = 1, #units do
        if ust[id].anchor then
          for _, t in ipairs(ust[id].mk.toks) do
            local _, changed = anchors.rewrite_dest(t, amap)
            if changed then
              info.anchors_changed = info.anchors_changed + 1
            end
          end
        end
        tick()
      end
      if #out ~= #lines then
        -- Cannot happen by construction; the invariant is hard, so the original wins.
        info.errors[#info.errors + 1] = "internal: line count changed, original returned"
        out = vim.list_slice(lines)
      end
      info.ms = (vim.uv.hrtime() - t0) / 1e6
      info.slices = sl.yields()
      finish(true, out, info)
    end

    ---Reflow and render in slices (see `slice.lua`). Nothing is left to do after the callback of
    ---the last answer but this: the engine part is over, so no answer can interleave.
    finalize = function()
      if resolving > 0 then
        -- (asked again by `release` when the last booking is through)
        finalize_wanted = true
        return
      end
      sl.run(function()
        if finished then
          return
        end
        if stale() then
          finish(false, "stale")
          return
        end
        with_map(finalize_rest)
      end)
    end

    if opts.cache_only or #misses == 0 then
      finalize()
      return
    end
    info.pending = 0

    -- Requests -------------------------------------------------------------------
    remaining = #misses
    local pending = {} ---@type { entries: table[], attempt: integer }[]
    local active, consec_fail = 0, 0
    local pumping = false
    local pump

    do
      local cur, cost = {}, 0
      for _, e in ipairs(misses) do
        tick()
        local c = #e.masked + 8
        if #cur > 0 and (cost + c > st.max_chars or #cur >= st.max_units) then
          pending[#pending + 1] = { entries = cur, attempt = 1 }
          cur, cost = {}, 0
        end
        cur[#cur + 1] = e
        cost = cost + c
      end
      if #cur > 0 then
        pending[#pending + 1] = { entries = cur, attempt = 1 }
      end
    end

    local function maybe_finish()
      if not finished and remaining == 0 and active == 0 and #pending == 0 then
        finalize()
      end
    end

    local function abort_rest(err)
      local list = pending
      pending = {}
      local skipped = {}
      for _, req in ipairs(list) do
        for _, e in ipairs(req.entries) do
          skipped[#skipped + 1] = e
        end
      end
      fail_entries(skipped, "skipped after repeated failures: " .. err)
    end

    ---Validate the answers of `req` (`res`, one line per entry), book the valid ones and queue or
    ---fail the rest.
    ---@param req table
    ---@param res string[]
    ---@param tk? fun()
    local function settle(req, res, tk)
      local invalid, first_err = {}, nil
      local answered = {}
      local write_model = use_cache and cache_model() or nil
      for i, e in ipairs(req.entries) do
        local value, err = validate(e, res[i], tk)
        if value then
          consec_fail = 0
          remaining = remaining - 1
          if use_cache then
            e.key = cache.key(engine, write_model, target, source, e.masked)
            cache.set(e.key, value)
          end
          resolve_entry(e, value, false)
          answered[#answered + 1] = e
        else
          invalid[#invalid + 1] = e
          first_err = first_err or err
        end
      end
      book_units(answered, true)
      if #invalid > 0 then
        if req.attempt == 1 then
          info.retries = info.retries + #invalid
          table.insert(pending, 1, { entries = invalid, attempt = 2 })
        else
          fail_entries(invalid, first_err or "invalid translation")
        end
      end
    end

    ---@param req table
    ---@param ok boolean
    ---@param res any
    ---@return boolean sliced  -- the answer is settled in a coroutine of its own, which pumps when it is through
    local function handle_result(req, ok, res)
      local n = #req.entries
      if ok and type(res) ~= "table" then
        ok, res = false, "the engine returned no lines"
      end
      if not ok then
        consec_fail = consec_fail + 1
        local err = tostring(res)
        if req.attempt == 1 and consec_fail < ABORT_AFTER then
          info.retries = info.retries + n
          table.insert(pending, 1, { entries = req.entries, attempt = 2 })
        else
          fail_entries(req.entries, err)
          if consec_fail >= ABORT_AFTER then
            abort_rest(err)
          end
        end
        return false
      end

      -- A parse of `out .. "\n"` may add one trailing empty line.
      local m = #res
      while m > n and res[m] == "" do
        m = m - 1
      end
      if m ~= n then
        if n == 1 then
          res = { table.concat(res, " ", 1, m) }
        elseif req.attempt == 1 then
          -- Cannot tell which unit grew a line break: one request per unit.
          info.retries = info.retries + n
          for i = n, 1, -1 do
            table.insert(pending, 1, { entries = { req.entries[i] }, attempt = 2 })
          end
          return false
        else
          fail_entries(req.entries, ("the engine returned %d lines for %d units"):format(m, n))
          return false
        end
      end

      local bytes = 0
      for i = 1, n do
        bytes = bytes + (type(res[i]) == "string" and #res[i] or 0)
      end
      if bytes <= SLICE_ANSWER_BYTES then
        settle(req, res)
        return false
      end
      -- A big answer: validated and booked in slices. `remaining` keeps the call open until the
      -- entries are settled, `resolving` keeps the finalisation back until the coroutine is through.
      resolving = resolving + 1
      sl.run(function()
        settle(req, res, tick)
        pump()
        release()
      end)
      return true
    end

    ---@param req table
    local function send(req)
      local texts = {}
      for i, e in ipairs(req.entries) do
        texts[i] = e.masked
      end
      active = active + 1
      info.requests = info.requests + 1
      local answered = false
      local job
      local function on_result(ok, res)
        if answered then
          return
        end
        answered = true
        active = active - 1
        if job then
          jobs[job] = nil
        end
        if finished then
          return
        end
        if stale() then
          finish(false, "stale")
          return
        end
        -- An answer arrives outside of the slicer's coroutines (a timer, a job callback, or inside
        -- `translate` itself, where `pcall` below would swallow the error): a throw in the inline
        -- booking (unmask, render, reflow, anchors) must end the call, not leave it hanging.
        -- (held: an engine that answers inside `translate` has it and the `pcall` below on the stack
        -- of the slicer's coroutine, and a yield must not cross them; a big answer is settled in a
        -- coroutine of its own, see `handle_result`)
        sl.hold(function()
          local booked, err = pcall(function()
            if not handle_result(req, ok, res) then
              pump()
            end
          end)
          if not booked then
            crashed(err)
          end
        end)
      end
      local started, j = pcall(provider.translate, texts, target, source, tr, on_result)
      if not started then
        on_result(false, tostring(j))
      elseif type(j) == "table" and not answered then
        job = j
        jobs[j] = true
      end
    end

    ---Is there a request to send and a free slot? (asked before and after every yield of `pump`)
    ---@return boolean
    local function can_send()
      return not finished and active < st.concurrency and #pending > 0
    end

    pump = function()
      if pumping then
        return
      end
      pumping = true
      while can_send() do
        -- An engine that answers inside `translate` makes this loop the whole engine phase.
        tick()
        -- The yield is a gap in which answers arrive: one may have aborted the rest (`pending` is
        -- empty now), ended the call, or filled the slots. The condition is asked again.
        if not can_send() then
          break
        end
        if stale() then
          pumping = false
          finish(false, "stale")
          return
        end
        send(table.remove(pending, 1))
      end
      pumping = false
      maybe_finish()
    end

    pump()
  end

  vim.schedule(function()
    if finished then
      return
    end
    sl.run(run)
  end)

  return handle
end

return M
