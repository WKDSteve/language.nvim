---@module 'language.translate.markdown.segment'
---@brief Cuts a Markdown document into literal lines and translation units.
---@description
--- Never translated (kept byte for byte): front matter, fenced and indented
--- code, math blocks, HTML blocks, reference definitions, thematic breaks,
--- setext underlines, blank lines and table delimiter rows. Translated:
--- headings, paragraphs, list items, block quotes, footnote definitions and
--- every table cell, each as a unit of its own.
---
--- The result is a line template. Every input line has one entry: either the
--- literal string, or a list of parts (strings and `{ u = unit, k = line }`
--- references) from which the line is rebuilt. A unit remembers the original
--- text of each of its lines, so rendering it back unchanged reproduces the
--- source exactly -- that is the fallback for a unit whose translation failed
--- validation.
---
--- Only the block structure is parsed (no inline parsing), but that one the way
--- CommonMark does it, with a stack of open containers (block quote, list item,
--- footnote): which containers continue on a line, then the open fence / HTML
--- block / table, then the blocks that start here, then what is left of the
--- line (see `M.segment`). Where a wrong guess would make code text it is
--- therefore the previewer's guess. (Checked against the previewer's renderer
--- on 20 000 random documents and on the Markdown files of the repos: see
--- `scripts/markdown_oracle.*`, `scripts/markdown_fuzz.lua`.) Two things are no
--- blocks of their own, as in the previewer: `$$` math and `[label]:`
--- definitions are lines inside a paragraph that stay as they are. A line taken
--- for code that was prose stays German, a line taken for prose that was code
--- is caught by the placeholder and plausibility checks. Hard line breaks (two
--- trailing spaces or a backslash) end a unit, since the reflow would otherwise
--- move them.

local M = {}

---@class LanguageMdUnit
---@field id integer
---@field block "heading"|"para"|"item"|"quote"|"cell"|"footnote"
---@field text string                       -- the content, lines joined by one space
---@field orig string[]                     -- content of each line (without prefix/suffix)
---@field weights integer[]                 -- width of each original line
---@field lines integer
---@field guard_first boolean               -- line 1 is not preceded by a block marker of its own
---@field pad "blank"|"zwsp"                -- how a surplus line of a short translation looks
---@field hard_backslash? boolean           -- the last line ends in a backslash break

---@class LanguageMdBlock
---@field first integer
---@field last integer
---@field units integer[]

---@class LanguageMdSegmentation
---@field tpl table<integer, string|table>
---@field units LanguageMdUnit[]
---@field blocks LanguageMdBlock[]
---@field headings integer[]                -- unit ids of headings, in document order
---@field defs table<string, boolean>       -- normalised reference-definition labels
---@field refdefs integer[]                 -- lines holding a reference definition

local BLOCK_TAGS = {}
for name in
  ([[address article aside base basefont blockquote body caption center col colgroup dd details
  dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head
  header hr html iframe legend li link main menu menuitem nav noframes ol optgroup option p param
  section source summary table tbody td tfoot th thead title tr track ul]]):gmatch("%S+")
do
  BLOCK_TAGS[name] = true
end

-- U+200B, the invisible padding of a surplus line.
local ZWSP = "\226\128\139"

local RAW_TAGS = { pre = true, script = true, style = true, textarea = true }

---@internal
---@param s string
---@return string content, string suffix
local function trim_right(s)
  -- A byte loop: `^(.-)[ \t]*$` retries the white space run from every byte inside it,
  -- quadratic on a long run.
  local e = #s
  while e > 0 do
    local b = s:byte(e)
    if b ~= 32 and b ~= 9 and b ~= 13 and b ~= 12 and b ~= 11 then
      break
    end
    e = e - 1
  end
  return s:sub(1, e), s:sub(e + 1)
end

---@internal
---@param line string
---@return boolean
local function is_blank(line)
  return line:match("^[ \t\r\f\v]*$") ~= nil
end

---@internal
---Start of an HTML block: kind of block and how it ends.
---@param rest string
---@param para_open boolean
---@return { kind: string, tag?: string }|nil
local function html_start(rest, para_open)
  local body = rest:match("^ ? ? ?(<.*)$")
  if not body then
    return nil
  end
  if body:sub(1, 4) == "<!--" then
    return { kind = "comment" }
  end
  if body:match("^<%?") then
    return { kind = "pi" }
  end
  if body:match("^<![%a]") then
    return { kind = "decl" }
  end
  local name = body:match("^</?(%a[%w-]*)")
  if not name then
    return nil
  end
  local lname = name:lower()
  local closing = body:sub(2, 2) == "/"
  local after = body:sub(#name + (closing and 3 or 2))
  if not closing and RAW_TAGS[lname] and (after == "" or after:match("^[ \t>]")) then
    return { kind = "raw", tag = lname }
  end
  if BLOCK_TAGS[lname] and (after == "" or after:match("^[ \t>/]")) then
    return { kind = "blank" }
  end
  if not para_open and body:match("^</?%a") then
    -- A complete tag on a line of its own. The first `<` or `>` after the name decides, one
    -- find: `^</?%a[%w-]*[^<>]*>[ \t\r]*$` backtracks over the name once per byte (run^2).
    local e = body:find("[<>]", 2)
    if e and body:byte(e) == 62 and body:find("^[ \t\r]*$", e + 1) then
      return { kind = "blank" }
    end
  end
  return nil
end

---@internal
---Does `line` end the HTML block `h`?
---@param h table
---@param line string
---@return boolean
local function html_ends(h, line)
  if h.kind == "comment" then
    return line:find("-->", 1, true) ~= nil
  elseif h.kind == "pi" then
    return line:find("?>", 1, true) ~= nil
  elseif h.kind == "decl" then
    return line:find(">", 1, true) ~= nil
  elseif h.kind == "raw" then
    -- Any of the four end tags closes it, not only its own (`<script>` ends at `</pre>`), and only the
    -- complete tag: `</prefix>` is no `</pre>`.
    local low = line:lower()
    for tag in pairs(RAW_TAGS) do
      if low:find("</" .. tag .. ">", 1, true) then
        return true
      end
    end
    return false
  end
  return false
end

---@internal
---Split a table row at its unescaped pipes. A pipe right behind a backslash is escaped whatever stands before
---that backslash (comrak keeps `\\|` in the cell, too).
---@param s string
---@return integer[] pipes
local function pipes(s)
  local out = {}
  for i = 1, #s do
    if s:byte(i) == 124 and (i == 1 or s:byte(i - 1) ~= 92) then
      out[#out + 1] = i
    end
  end
  return out
end

---@internal
---Which lines of a paragraph end inside a code span? A span may run over several
---lines, and then a hard break at the end of one of them (a backslash, two spaces)
---belongs to the code, not to the paragraph. The spans are paired the way
---CommonMark pairs them: a run of backticks closes with the next run of the same
---length; one that finds no partner is text.
---@param plines { content: string }[]
---@return table<integer, boolean>
local function code_span_ends(plines)
  local runs, any = {}, false
  for i, ln in ipairs(plines) do
    if ln.content:find("`", 1, true) then
      any = true
      local at = 1
      while true do
        local a, b = ln.content:find("`+", at)
        if not a then
          break
        end
        local k = 0 -- backslashes right before the run, counted backwards: linear
        while a - 1 - k >= 1 and ln.content:byte(a - 1 - k) == 92 do
          k = k + 1
        end
        local escaped = k % 2 == 1
        runs[#runs + 1] = { line = i, len = b - a + 1, open_len = b - a + 1 - (escaped and 1 or 0) }
        at = b + 1
      end
    end
  end
  local inside = {}
  if not any then
    return inside
  end
  ---@type table<integer, integer[]>
  local by_len = {}
  for idx, r in ipairs(runs) do
    local l = by_len[r.len] or {}
    by_len[r.len] = l
    l[#l + 1] = idx
  end
  local pos = {} ---@type table<integer, integer>
  local i = 1
  while i <= #runs do
    local r = runs[i]
    local partner
    if r.open_len >= 1 then
      local list = by_len[r.open_len]
      if list then
        local k = pos[r.open_len] or 1
        while list[k] and list[k] <= i do
          k = k + 1
        end
        pos[r.open_len] = k
        partner = list[k]
      end
    end
    if partner then
      for l = r.line, runs[partner].line - 1 do
        inside[l] = true
      end
      i = partner + 1
    else
      i = i + 1
    end
  end
  return inside
end

---@internal
---Is the thematic break (`***`, `---`, `___`, spaces between allowed) at byte `i` of `s`? Early exit on
---the first foreign byte: linear, no copy of the rest of the line. When it is none, the second result is
---the index of the byte that said so (a caller that asks again further right on the same line, as the
---nesting `- - - x` does, can skip every position up to it).
---@param s string
---@param i integer
---@return boolean, integer|nil
local function is_hr_at(s, i)
  local ch = s:byte(i)
  if ch ~= 45 and ch ~= 42 and ch ~= 95 then
    return false
  end
  local count = 0
  while true do
    local c = s:byte(i)
    if c == nil then
      break
    end
    if c == ch then
      count = count + 1
    elseif c ~= 32 and c ~= 9 and c ~= 13 then
      return false, i
    end
    i = i + 1
  end
  return count >= 3
end

---@internal
---Cells of a table row: leading and trailing pipe are optional, `\|` is text. 0 for a row without any cell.
---@param text string
---@return integer
local function row_cells(text)
  local s, e = 1, #text
  while e >= s and (text:byte(e) == 32 or text:byte(e) == 9 or text:byte(e) == 13) do
    e = e - 1
  end
  while s <= e and (text:byte(s) == 32 or text:byte(s) == 9) do
    s = s + 1
  end
  if s > e then
    return 0
  end
  if text:byte(s) == 124 then
    s = s + 1
  end
  -- A pipe right behind a backslash is escaped whatever stands before that backslash (`\\|` too, as in
  -- `pipes`): a trailing pipe closes the last cell unless it is escaped, every other one starts a cell.
  if e >= s and text:byte(e) == 124 and (e == 1 or text:byte(e - 1) ~= 92) then
    e = e - 1
  end
  if s > e then
    return 0
  end
  local n = 1
  for i = s, e do
    if text:byte(i) == 124 and (i == 1 or text:byte(i - 1) ~= 92) then
      n = n + 1
    end
  end
  return n
end

---@internal
---Cells of a delimiter row (`|---|:-:|`) at byte `np` of `line`, or nil when it is none.
---@param line string
---@param np integer
---@return integer|nil
local function delimiter_cells(line, np)
  if not line:find("|", np, true) or not line:find("-", np, true) then
    return nil
  end
  local s = line:sub(np)
  local e = #s
  while e > 0 and s:find("^[ \t\r]", e) do
    e = e - 1
  end
  s = s:sub(1, e)
  s = s:gsub("^|", ""):gsub("|$", "")
  if s == "" then
    return nil
  end
  local n = 0
  for cell in (s .. "|"):gmatch("([^|]*)|") do
    if not cell:match("^[ \t]*:?%-+:?[ \t]*$") then
      return nil
    end
    n = n + 1
  end
  return n
end

---Segment a document.
---`tick` (optional) is called after each line (and every 1024 cells of a table row), once the state of the scan is complete: it may
---give the control away (`translate_markdown` slices big documents that way) and returns when the
---scan goes on. It must not touch the arguments.
---
---The scan follows the CommonMark container algorithm: a stack of open containers (block quote, list
---item, footnote), and per line (1) the containers that continue, (2) an open fence / HTML block,
---(3) the blocks that start here (inside the containers that matched), (4) what is left of the line:
---a blank, a lazy or ordinary continuation of the paragraph, a table row, or a new paragraph. A math
---block (`$$`) and a reference definition are no blocks: their lines stay as they are inside the
---paragraph, which a block start ends (the previewer's reading). Columns are counted with tab stops
---of four, so the content column of an item and the "at most three columns of indent" rule mean what
---the previewer's renderer means by them.
---@param lines string[]
---@param tick? fun()
---@return LanguageMdSegmentation
function M.segment(lines, tick)
  local n = #lines
  ---@type LanguageMdSegmentation
  local seg = { tpl = {}, units = {}, blocks = {}, headings = {}, defs = {}, refdefs = {} }
  local tpl, units, blocks = seg.tpl, seg.units, seg.blocks

  -- Open containers, outermost first: { t = "quote" } | { t = "item"|"footnote", w = width of the content, counted from where the container around it
  -- has its content on the line, has = bool }. Relative, as CommonMark has it: two lines may reach the
  -- same item through quote prefixes of different width (`> - a` / `  > b`).
  -- `has`: the item holds a block already (an empty item does not survive a blank line).
  local stack = {}
  local nquote, nitem = 0, 0 -- quotes / items+footnotes in the stack
  -- The open leaf, if any: a paragraph (`t = "para"`), a fence, an HTML block or a table.
  local leaf
  local no_close_after ---@type integer|nil -- no `$$` below this line: a `$$` opens no block

  -- cursor in the current line: byte `pos` starts at column `col`; `eoff` columns of a tab there are consumed
  local line, pos, col, eoff = "", 1, 0, 0

  ---First byte that is no space or tab at or behind the cursor, and its column.
  ---@return integer np, integer nc
  local function scan()
    local p, c = pos, col
    while true do
      local b = line:byte(p)
      if b == 32 then
        c = c + 1
      elseif b == 9 then
        c = c + 4 - c % 4
      else
        break
      end
      p = p + 1
    end
    return p, c
  end

  ---Move the cursor to column `target` over white space (a tab may be consumed in part).
  ---@param target integer
  local function advance_to(target)
    while col + eoff < target do
      local b = line:byte(pos)
      if b == 32 then
        col, pos, eoff = col + 1, pos + 1, 0
      elseif b == 9 then
        local width = 4 - col % 4
        if col + width <= target then
          col, pos, eoff = col + width, pos + 1, 0
        else
          eoff = target - col
          return
        end
      else
        return
      end
    end
  end

  ---@param u table
  ---@return LanguageMdUnit
  local function add_unit(u)
    units[#units + 1] = u
    u.id = #units
    return u
  end

  local function close_para()
    local p = leaf
    if not p or p.t ~= "para" then
      return
    end
    leaf = nil
    local inside = code_span_ends(p.lines)
    local runs, cur = {}, {}
    for i, ln in ipairs(p.lines) do
      if ln.hard and inside[i] then
        -- Inside a code span a trailing backslash or double space is just text.
        ln.hard = false
        if ln.suffix:sub(1, 1) == "\\" then
          ln.content = ln.content .. "\\"
          ln.suffix = ln.suffix:sub(2)
        end
      end
      if ln.lit then
        -- a math line: stays as it is and ends the run of text before it
        if #cur > 0 then
          runs[#runs + 1] = cur
          cur = {}
        end
        tpl[ln.L] = lines[ln.L]
      else
        cur[#cur + 1] = ln
        if ln.hard and i < #p.lines then
          runs[#runs + 1] = cur
          cur = {}
        end
      end
    end
    if #cur > 0 then
      runs[#runs + 1] = cur
    end
    if #runs == 0 then
      return
    end
    -- a surplus line of the last run may be blank only when the paragraph really ends there
    local tail_lit = p.lines[#p.lines].lit == true
    local blk = { first = runs[1][1].L, last = runs[#runs][#runs[#runs]].L, units = {} }
    for ri, run in ipairs(runs) do
      local u = add_unit({
        block = p.kind,
        lines = #run,
        orig = {},
        weights = {},
        -- A setext heading has no marker in front of its first line: guard it like text.
        guard_first = p.kind ~= "heading" or p.setext == true,
        hard_backslash = run[#run].hard and run[#run].suffix:sub(1, 1) == string.char(92) or false,
        pad = (
          p.kind == "para"
          and not p.listctx
          and p.qdepth == 0
          and ri == #runs
          and not tail_lit
          and not run[#run].hard
        )
            and "blank"
          or "zwsp",
      })
      for k, ln in ipairs(run) do
        u.orig[k] = ln.content
        u.weights[k] = math.max(#ln.content, 1)
        tpl[ln.L] = { ln.prefix, { u = u.id, k = k }, ln.suffix }
      end
      u.text = table.concat(u.orig, " ")
      blk.units[#blk.units + 1] = u.id
      if p.kind == "heading" then
        seg.headings[#seg.headings + 1] = u.id
      end
    end
    blocks[#blocks + 1] = blk
  end

  ---@param L integer
  ---@param prefix string
  ---@param body string
  ---@return table
  local function make_line(L, prefix, body)
    local content, suffix = trim_right(body)
    local hard = false
    local bs = 0 -- trailing backslashes
    while bs < #content and content:byte(#content - bs) == 92 do
      bs = bs + 1
    end
    if bs % 2 == 1 and #content > 1 then
      hard = true
      content = content:sub(1, -2)
      suffix = "\\" .. suffix
    elseif #suffix >= 2 and suffix:sub(1, 2) == "  " then
      hard = true
    end
    return { L = L, prefix = prefix, content = content, suffix = suffix, hard = hard }
  end

  ---The leaf ends (a paragraph becomes its units).
  local function close_leaf()
    if leaf then
      close_para()
      leaf = nil
    end
  end

  ---Close the containers that did not continue (`m` stay) and the leaf inside of them.
  ---@param m integer
  local function pop_to(m)
    while #stack > m do
      local c = stack[#stack]
      if c.t == "quote" then
        nquote = nquote - 1
      else
        nitem = nitem - 1
      end
      stack[#stack] = nil
    end
  end

  ---The innermost container holds a block now.
  local function mark_content()
    local c = stack[#stack]
    if c then
      c.has = true
    end
  end

  ---A heading of a single line.
  local function heading_unit(L, prefix, content, suffix)
    local u = add_unit({
      block = "heading",
      lines = 1,
      orig = { content },
      weights = { math.max(#content, 1) },
      guard_first = false,
      pad = "zwsp",
      text = content,
    })
    tpl[L] = { prefix, { u = u.id, k = 1 }, suffix }
    blocks[#blocks + 1] = { first = L, last = L, units = { u.id } }
    seg.headings[#seg.headings + 1] = u.id
  end

  ---A table row: every non-empty cell is a unit.
  local function table_row(L, qpfx, rest)
    local ps = pipes(rest)
    local parts, ids = { qpfx }, {}
    local from = 1
    local cells = 0
    local function cell(a, b)
      -- A very long row is one line to the loop below: hand the control back inside it.
      cells = cells + 1
      if tick and cells % 1024 == 0 then
        tick()
      end
      local seg_text = rest:sub(a, b)
      local lead, body = seg_text:match("^([ \t]*)(.*)$")
      local content, tail = trim_right(body)
      parts[#parts + 1] = lead
      if content ~= "" then
        local u = add_unit({
          block = "cell",
          lines = 1,
          orig = { content },
          weights = { math.max(#content, 1) },
          -- The first cell of a row without a leading pipe starts the line itself.
          guard_first = from == 1,
          pad = "zwsp",
          text = content,
        })
        parts[#parts + 1] = { u = u.id, k = 1 }
        ids[#ids + 1] = u.id
      end
      parts[#parts + 1] = tail
    end
    for _, p in ipairs(ps) do
      cell(from, p - 1)
      parts[#parts + 1] = "|"
      from = p + 1
    end
    cell(from, #rest)
    tpl[L] = parts
    if #ids > 0 then
      blocks[#blocks + 1] = { first = L, last = L, units = ids }
    else
      tpl[L] = lines[L]
    end
  end

  ---Is the line a line of a math block (`$$` ... `$$`)? comrak knows no math block: the dollars are inline
  ---math in the text of a paragraph, which any block start ends. So a math block here is a run of lines
  ---inside a paragraph that stay as they are (the mask does not protect formulas). A `$$` that nothing
  ---closes is text, and so is one indented four columns.
  ---@param L integer
  ---@param np integer
  ---@param p table|nil  -- the paragraph the line is added to; nil: it starts one
  ---@param indent integer
  ---@return boolean lit, boolean opens
  local function math_line(L, np, p, indent)
    if p and p.math_open then
      if line:find("$$", 1, true) then
        p.math_open = false
      end
      return true, false
    end
    if indent > 3 or not line:find("^%$%$", np) then
      return false, false
    end
    if line:find("$$", np + 2, true) then
      return true, false
    end
    if no_close_after and L >= no_close_after then
      return false, false
    end
    for j = L + 1, n do
      if lines[j]:find("$$", 1, true) then
        return true, true
      end
    end
    no_close_after = L
    return false, false
  end

  ---The line record of a math line (it keeps its place in the paragraph, but is no text).
  ---@param L integer
  ---@return table
  local function lit_line(L)
    return {
      L = L,
      prefix = "",
      content = "",
      suffix = "",
      hard = false,
      lit = true,
      qlen = pos - 1,
    }
  end

  ---The line is a reference definition: it stays as it is, together with the destination / title line
  ---below it (a lookahead on the raw lines). The lines join paragraph `p` as literal lines.
  ---@param L integer
  ---@param np integer
  ---@param p table
  ---@return integer took  -- the lines after `L` that were taken along
  local function ref_lines(L, np, p)
    local label, tail = line:match("^%[([^%]^][^%]]*)%]:(.*)$", np)
    p.lines[#p.lines + 1] = lit_line(L)
    seg.defs[require("language.translate.markdown.mask")._norm_label(label)] = true
    seg.refdefs[#seg.refdefs + 1] = L
    local took = 0
    ---Line `N` without the quote markers of the quotes the definition stands in (as many as it has: one
    ---with fewer is a lazy continuation, its text still goes on).
    ---@param N integer
    ---@return string|nil
    local function inner(N)
      local s = lines[N]
      for _ = 1, s and nquote or 0 do
        local r = s:match("^[ \t]*>[ ]?(.*)$")
        if not r then
          break
        end
        s = r
      end
      return s
    end
    local nxt = inner(L + 1)
    -- `[label]:` alone: the destination is on the next line. That line stays as it
    -- is: a translation that came out as one word would become the destination
    -- and swallow the paragraph. (A line that starts a block is none.)
    if
      is_blank(tail)
      and nxt
      and nxt:match("^[ \t]*[^ \t\r#>|<`]")
      -- a bullet marker or a thematic break / setext underline starts a block, `-->` is a destination
      and not nxt:match("^[ \t]*[*+%-][ \t\r]")
      and not nxt:match("^[ \t]*[*+%-]$")
      and not nxt:match("^[ \t]*[*_=%-][ \t*_=%-]*$")
      and not nxt:match("^[ \t]*```+[^`]*$")
      and not nxt:match("^[ \t]*~~~+")
      -- an ordered item starts a block of its own (`1. text`), it is no destination
      and not nxt:match("^[ \t]*%d+[.)][ \t\r]")
      and not nxt:match("^[ \t]*%d+[.)]$")
    then
      p.lines[#p.lines + 1] = lit_line(L + 1)
      took = took + 1
      nxt = inner(L + 1 + took)
    end
    if nxt and nxt:match("^[ \t]+[\"'(]") then
      p.lines[#p.lines + 1] = lit_line(L + 1 + took)
      took = took + 1
    end
    return took
  end

  ---A new paragraph (or what its first line says it is).
  ---@param L integer
  ---@param np integer  -- byte where the text starts
  ---@param kind string
  ---@param indent integer
  local function open_para(L, np, kind, indent)
    mark_content()
    local lit, opens = math_line(L, np, nil, indent)
    leaf = {
      t = "para",
      kind = kind,
      lines = { lit and lit_line(L) or make_line(L, line:sub(1, np - 1), line:sub(np)) },
      qdepth = nquote,
      listctx = nitem > 0,
      math_open = opens or nil,
    }
    leaf.lines[1].qlen = pos - 1
  end

  ---Handle line `L`. Returns how many further lines it consumed (a reference definition takes its
  ---destination and title lines along).
  ---@param L integer
  ---@return integer
  local function handle(L)
    line = lines[L]
    pos, col, eoff = 1, 0, 0

    -- (1) the containers that continue
    local matched = 0
    for i = 1, #stack do
      local c = stack[i]
      local np, nc = scan()
      if c.t == "quote" then
        if nc - (col + eoff) <= 3 and line:byte(np) == 62 then
          advance_to(nc)
          pos, col, eoff = pos + 1, col + 1, 0
          local b = line:byte(pos)
          if b == 32 then
            pos, col = pos + 1, col + 1
          elseif b == 9 then
            advance_to(col + 1)
          end
          matched = i
        else
          break
        end
      elseif line:find("^[\r\f\v]*$", np) then
        -- a blank line: an item that holds a block goes on, an empty one ends. A footnote goes on at a line
        -- that is really empty or indented like its text (the previewer ends it at one of one to three spaces)
        if c.has and (c.t ~= "footnote" or line:find("^\r*$", pos) or nc - (col + eoff) >= c.w) then
          matched = i
        else
          break
        end
      elseif nc - (col + eoff) >= c.w then
        advance_to(col + eoff + c.w)
        matched = i
      else
        break
      end
    end
    local all = matched == #stack

    -- (2) an open fence or HTML block
    if leaf and all then
      local t = leaf.t
      if t == "fence" then
        local np, nc = scan()
        if nc - (col + eoff) <= 3 then
          local i = np
          while line:byte(i) == leaf.ch do
            i = i + 1
          end
          if i - np >= leaf.len and line:find("^[ \t\r]*$", i) then
            leaf = nil
          end
        end
        tpl[L] = line
        return 0
      elseif t == "html" then
        if leaf.h.kind == "blank" and line:find("^[ \t\r\f\v]*$", pos) then
          leaf = nil
        else
          tpl[L] = line
          if leaf.h.kind ~= "blank" and html_ends(leaf.h, line) then
            leaf = nil
          end
          return 0
        end
      end
    elseif leaf and not all and leaf.t ~= "para" then
      leaf = nil -- a fence, HTML block or table ends with its container
    end

    -- (3) the blocks that start here
    local interrupt = all and leaf ~= nil and leaf.t == "para"
    local maybe_lazy = leaf ~= nil and leaf.t == "para"
    local item_first = false -- an item marker was consumed on this line: its text is the item's
    local footnote_first = false
    local np, nc, blank
    local hr_ch, hr_fail = nil, 0

    ---Containers that did not continue end, and so does the leaf: something new starts.
    local function settle()
      pop_to(matched)
      close_leaf()
      interrupt, maybe_lazy, all = false, false, true
    end

    while true do
      local again = false
      repeat
        np, nc = scan()
        blank = line:find("^[\r\f\v]*$", np) ~= nil
        if blank then
          break
        end
        local indent = nc - (col + eoff)
        if indent >= 4 then
          if not maybe_lazy then
            -- indented code
            settle()
            mark_content()
            tpl[L] = line
            return 0
          end
          break
        end
        local b = line:byte(np)

        if b == 62 then
          -- block quote
          settle()
          matched = #stack
          mark_content()
          stack[#stack + 1] = { t = "quote" }
          nquote = nquote + 1
          matched = #stack
          advance_to(nc)
          pos, col, eoff = pos + 1, col + 1, 0
          local nb = line:byte(pos)
          if nb == 32 then
            pos, col = pos + 1, col + 1
          elseif nb == 9 then
            advance_to(col + 1)
          end
          item_first, footnote_first = false, false
          again = true
          break
        end

        if b == 35 then
          -- ATX heading
          local hashes, hsp, htext = line:match("^(#+)([ \t]+)(.*)$", np)
          if hashes and #hashes <= 6 then
            settle()
            mark_content()
            -- A closing sequence (`## Title ##`): hashes behind white space at the end.
            local body
            do
              local e = #htext
              while e > 0 and (htext:byte(e) == 32 or htext:byte(e) == 9 or htext:byte(e) == 13) do
                e = e - 1
              end
              local cut = e
              while cut > 0 and htext:byte(cut) == 35 do
                cut = cut - 1
              end
              if cut < e and cut > 0 and (htext:byte(cut) == 32 or htext:byte(cut) == 9) then
                while cut > 0 and (htext:byte(cut) == 32 or htext:byte(cut) == 9) do
                  cut = cut - 1
                end
                body = htext:sub(1, cut)
              end
            end
            local content, suffix
            if body then
              content, suffix = trim_right(body)
              suffix = suffix .. htext:sub(#body + 1)
            else
              content, suffix = trim_right(htext)
            end
            if content == "" then
              tpl[L] = line
            else
              heading_unit(L, line:sub(1, np - 1) .. hashes .. hsp, content, suffix)
            end
            return 0
          end
          if line:find("^#+[ \t\r]*$", np) then
            settle()
            mark_content()
            tpl[L] = line
            return 0
          end
        end

        if b == 96 or b == 126 then
          -- fenced code
          local i = np
          while line:byte(i) == b do
            i = i + 1
          end
          if i - np >= 3 and (b == 126 or not line:find("`", i, true)) then
            settle()
            mark_content()
            tpl[L] = line
            leaf = { t = "fence", ch = b, len = i - np }
            return 0
          end
        end

        if b == 60 then
          -- HTML block
          local rs = line:sub(np)
          local h = html_start(rs, interrupt)
          if h then
            settle()
            mark_content()
            tpl[L] = line
            if h.kind == "blank" or not html_ends(h, rs:sub(2)) then
              leaf = { t = "html", h = h }
            end
            return 0
          end
        end

        if interrupt and (b == 61 or b == 45) then
          -- setext underline: the paragraph above ends here
          if line:find("^=+[ \t\r]*$", np) or line:find("^%-+[ \t\r]*$", np) then
            if leaf.defs_only then
              -- a paragraph of nothing but definitions has no text to underline: comrak makes the underline
              -- its text (`===` or `---`), and a `-` below may underline that in turn
              leaf.defs_only = nil
              leaf.lines[#leaf.lines + 1] = lit_line(L)
              return 0
            end
            local p = leaf
            if p and p.kind == "para" then
              p.kind = "heading"
              p.setext = true
            end
            close_leaf()
            tpl[L] = line
            return 0
          end
        end

        if b == 45 or b == 42 or b == 95 then
          -- a thematic break check that failed at byte `hr_fail` fails again for every start left of it
          local is_hr = false
          if not (hr_ch == b and np <= hr_fail) then
            local found, failed_at = is_hr_at(line, np)
            is_hr = found
            if not found and failed_at then
              hr_ch, hr_fail = b, failed_at
            end
          end
          if is_hr then
            settle()
            mark_content()
            tpl[L] = line
            return 0
          end
        end

        if b == 91 then
          -- footnote definition: a container of its own, its text continues four columns in
          local label, ftail = line:match("^%[%^([^%]]+)%]:(.*)$", np)
          if label then
            settle()
            mark_content()
            if is_blank(ftail) then
              tpl[L] = line
              return 0
            end
            stack[#stack + 1] = { t = "footnote", w = 4, has = true }
            nitem = nitem + 1
            matched = #stack
            local close = line:find("]:", np, true)
            pos, col, eoff = close + 2, nc + (close + 2 - np), 0
            footnote_first = true
            again = true
            break
          end
        end

        if b == 45 or b == 42 or b == 43 or (b >= 48 and b <= 57) then
          -- list item
          local mlen, ordered, num
          if b >= 48 and b <= 57 then
            local digits = line:match("^(%d+)[.)]", np)
            if digits and #digits <= 9 then
              mlen, ordered, num = #digits + 1, true, tonumber(digits)
            end
          else
            mlen = 1
          end
          local after = mlen and np + mlen
          local ab = after and line:byte(after)
          if mlen and (ab == nil or ab == 32 or ab == 9 or ab == 13) then
            local empty = line:find("^[ \t\r]*$", after) ~= nil
            if not (interrupt and (empty or (ordered and num ~= 1))) then
              -- columns of white space behind the marker
              local c2 = nc + mlen
              local p2 = after
              while true do
                local sb = line:byte(p2)
                if sb == 32 then
                  c2 = c2 + 1
                elseif sb == 9 then
                  c2 = c2 + 4 - c2 % 4
                else
                  break
                end
                p2 = p2 + 1
              end
              local gap = c2 - (nc + mlen)
              local w = (empty or gap >= 5) and nc + mlen + 1 or nc + mlen + gap
              settle()
              mark_content()
              stack[#stack + 1] = { t = "item", w = w - (col + eoff), has = false }
              nitem = nitem + 1
              matched = #stack
              advance_to(nc)
              pos, col, eoff = pos + mlen, col + mlen, 0
              advance_to(w)
              item_first, footnote_first = true, false
              again = true
              break
            end
          end
        end

        local para_above = leaf
        if interrupt and para_above then
          -- table: the delimiter row under a one-line header (the last line of the paragraph)
          local cells = delimiter_cells(line, np)
          if cells then
            local hdr = para_above.lines[#para_above.lines]
            if not hdr.lit and row_cells(lines[hdr.L]:sub(hdr.qlen + 1)) == cells then
              para_above.lines[#para_above.lines] = nil
              if #para_above.lines > 0 then
                close_para()
              else
                leaf = nil
              end
              mark_content()
              local hl = lines[hdr.L]
              table_row(hdr.L, hl:sub(1, hdr.qlen), hl:sub(hdr.qlen + 1))
              tpl[L] = line
              leaf = { t = "table" }
              return 0
            elseif not hdr.lit then
              -- No table by the cell count. But a translation that adds or drops a pipe in the header line
              -- would make one of it: the header and the delimiter row stay as they are.
              hdr.lit, hdr.prefix, hdr.content, hdr.suffix, hdr.hard = true, "", "", "", false
              para_above.lines[#para_above.lines + 1] = lit_line(L)
              return 0
            end
          end
        end

      until true
      if not again then
        break
      end
    end

    -- (4) what is left of the line
    if blank then
      settle()
      tpl[L] = line
      return 0
    end

    if leaf and leaf.t == "para" then
      -- an ordinary or a lazy continuation of the paragraph
      if leaf.defs_only then
        -- the paragraph has held nothing but reference definitions so far: one more is one more, whatever its
        -- indent (the lines of a paragraph lose their indent)
        if line:find("^%[[^%]^][^%]]*%]:", np) then
          return ref_lines(L, np, leaf)
        end
        leaf.defs_only = nil
      end
      local lit, opens = math_line(L, np, leaf, nc - (col + eoff))
      local ln = lit and lit_line(L) or make_line(L, line:sub(1, np - 1), line:sub(np))
      ln.qlen = pos - 1
      leaf.lines[#leaf.lines + 1] = ln
      if opens then
        leaf.math_open = true
      end
      return 0
    end

    if leaf and leaf.t == "table" and all then
      table_row(L, line:sub(1, pos - 1), line:sub(pos))
      return 0
    end

    settle()

    -- a task box in front of the text of an item is no part of the text
    if item_first then
      local box = line:match("^%[[ xX]%][ \t]+", np)
      if box then
        np = np + #box
        if line:find("^[\r\f\v]*$", np) then
          -- the box alone is still the item's paragraph: a line below goes on with it (lazily, too), so a
          -- list that interrupts it is a list and no continuation
          mark_content()
          leaf = {
            t = "para",
            kind = "item",
            lines = { lit_line(L) },
            qdepth = nquote,
            listctx = nitem > 0,
          }
          leaf.lines[1].qlen = pos - 1
          return 0
        end
        open_para(L, np, "item", nc - (col + eoff))
        return 0
      end
    end

    local kind
    if footnote_first then
      kind = "footnote"
    elseif item_first then
      kind = "item"
    elseif nquote > 0 then
      kind = "quote"
    elseif nitem > 0 then
      kind = "item"
    else
      kind = "para"
    end

    -- Reference definition: stays as it is, together with the destination / title line below it. comrak cuts
    -- the definitions off a paragraph when it ends, so the line starts a paragraph (its text goes on below it,
    -- a list cannot interrupt it...) whose first lines stay as they are, like the lines of a math block.
    if not footnote_first and line:find("^%[[^%]^][^%]]*%]:", np) then
      mark_content()
      leaf = {
        t = "para",
        kind = kind,
        lines = {},
        qdepth = nquote,
        listctx = nitem > 0,
        defs_only = true,
      }
      return ref_lines(L, np, leaf)
    end

    open_para(L, np, kind, nc - (col + eoff))
    return 0
  end

  local L = 1

  -- Front matter: `---` ... `---`/`...`, or `+++` ... `+++`, at the very top.
  do
    local delim = lines[1]
      and (lines[1]:match("^(%-%-%-)[ \t\r]*$") or lines[1]:match("^(%+%+%+)[ \t\r]*$"))
    if delim then
      for j = 2, n do
        local l = lines[j]
        if
          l:match("^" .. delim:gsub("%p", "%%%0") .. "[ \t\r]*$")
          or (delim == "---" and l:match("^%.%.%.[ \t\r]*$"))
        then
          -- `---` is front matter only when it opens with a `key:` line (the
          -- previewer's rule): a horizontal rule at the top of a document, with
          -- another one far below, must not make the text in between "metadata".
          local first
          for i = 2, j - 1 do
            if not is_blank(lines[i]) then
              first = lines[i]
              break
            end
          end
          if delim == "---" and not (first and first:match("^[^%s:][^%s:]*:")) then
            break
          end
          for i = 1, j do
            tpl[i] = lines[i]
          end
          L = j + 1
          break
        end
      end
    end
  end

  while L <= n do
    local took = handle(L)
    L = L + 1 + took
    if tick then
      tick()
    end
  end
  close_leaf()

  for i = 1, n do
    if tpl[i] == nil then
      tpl[i] = lines[i]
    end
    if tick and i % 256 == 0 then
      tick()
    end
  end
  return seg
end

---Render lines `first..last` of the template. `content[u]` holds the lines of
---unit `u` (without prefix and suffix); a unit without an entry is rendered
---as it was in the source.
---@param seg LanguageMdSegmentation
---@param content table<integer, string[]>
---@param first? integer
---@param last? integer
---@param tick? fun()  -- called after each line (see `M.segment`)
---@return string[]
function M.render(seg, content, first, last, tick)
  local out, n = {}, 0
  for L = first or 1, last or #seg.tpl do
    local t = seg.tpl[L]
    n = n + 1
    if type(t) == "string" then
      out[n] = t
    else
      local buf = {}
      for i, part in ipairs(t) do
        if type(part) == "string" then
          buf[i] = part
        else
          local c = content[part.u]
          if c then
            local v = c[part.k]
            if v == "" and seg.units[part.u].pad == "zwsp" then
              v = ZWSP
            end
            buf[i] = v
          else
            buf[i] = seg.units[part.u].orig[part.k]
          end
        end
      end
      out[n] = table.concat(buf)
    end
    if tick then
      tick()
    end
  end
  return out
end

return M
