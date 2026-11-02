-- TESTS/translate_chunk_spec.lua — language.translate.chunk: splitting large
-- translate inputs into provider-sized, line-aligned blocks, and the wrapper
-- every registry provider goes through. A fake provider/runner only: no curl,
-- no network. The wrapper's contract is what the callers rely on: line count
-- preserved, `cb` exactly once, a failed block fails the call, cancel stops it.

return function(H)
  local chunk = require("language.translate.chunk")

  --- A fake provider that "translates" by upper-casing and records each call.
  ---@param limits table
  ---@param on_call? fun(lines: string[], cb: function, n: integer): table|nil
  local function fake(limits, on_call)
    local p = { name = "fake", limits = limits, calls = {} }
    p.available = function()
      return true
    end
    p.translate = function(lines, _t, _s, _c, cb)
      p.calls[#p.calls + 1] = lines
      if on_call then
        return on_call(lines, cb, #p.calls)
      end
      local out = {}
      for i, l in ipairs(lines) do
        out[i] = l:upper()
      end
      cb(true, out)
      return { cancel = function() end }
    end
    return p
  end

  local function run(provider, lines, cfg)
    local wrapped = chunk.wrap(provider)
    local calls, ok, result = 0, nil, nil
    local job = wrapped.translate(lines, "DE", nil, cfg or {}, function(o, r)
      calls, ok, result = calls + 1, o, r
    end)
    return {
      calls = function()
        return calls
      end,
      ok = function()
        return ok
      end,
      result = function()
        return result
      end,
      job = job,
    }
  end

  -- split(): boundaries --------------------------------------------------------
  local blocks = chunk.split({ "aaaa", "bbbb", "cccc", "dddd" }, { max_bytes = 10 })
  H.eq(#blocks, 2, "4 lines of cost 5 under a budget of 10: two blocks")
  H.eq(blocks[1].last, 2, "the first block ends after line 2")
  H.eq(blocks[2].first, 3, "and the next one starts right after it")

  local para = { "one", "two", "", "three", "four", "five", "six" }
  local pb = chunk.split(para, { max_bytes = 21 })
  H.eq(pb[1].last, 3, "a cut prefers the blank line (paragraph boundary)")
  H.eq(pb[2].first, 4, "so the next paragraph starts a block")

  local covered = 0
  for _, b in ipairs(chunk.split(vim.fn.split(string.rep("x\n", 50), "\n"), { max_bytes = 7 })) do
    covered = covered + (b.last - b.first + 1)
  end
  H.eq(covered, 50, "the blocks cover every line exactly once")

  local capped = chunk.split({ "a", "b", "c", "d", "e" }, { max_bytes = 1000, max_lines = 2 })
  H.eq(#capped, 3, "max_lines caps the block size (DeepL: 50 texts per request)")

  local bad, err = chunk.split({ "ok", string.rep("y", 50) }, { max_bytes = 10 })
  H.eq(bad, nil, "a single line over the budget cannot be split")
  H.contains(err, "line 2", "the message names the line")

  -- limits_for(): max_chars only lowers ------------------------------------------
  local p0 = fake({ max_bytes = 100 })
  H.eq(chunk.limits_for(p0, { max_chars = 40 }).max_bytes, 40, "max_chars lowers the budget")
  H.eq(chunk.limits_for(p0, { max_chars = 400 }).max_bytes, 100, "but never raises it")
  H.eq(chunk.limits_for(p0, { max_chars = 0 }).max_bytes, 100, "0 means the engine default")
  H.eq(chunk.limits_for({ name = "x" }, {}), nil, "no limits declared: nothing to enforce")

  -- wrap(): >32 700 characters never reach the provider as one payload ----------
  local big = {}
  for i = 1, 800 do
    big[i] = ("line %04d "):format(i) .. string.rep("w", 40)
  end
  local total = #table.concat(big, "\n")
  H.ok(total > 32700, "fixture is above the Windows command-line limit (" .. total .. ")")
  local pbig = fake({ max_bytes = 6000 })
  local r = run(pbig, big)
  H.ok(r.ok(), "the oversized input is translated")
  H.eq(r.calls(), 1, "cb runs exactly once")
  H.ok(#pbig.calls > 1, "in several blocks")
  for _, c in ipairs(pbig.calls) do
    H.ok(#table.concat(c, "\n") <= 6000, "every block respects the budget")
  end
  H.eq(#r.result(), 800, "the line count is preserved")
  H.eq(r.result()[1], big[1]:upper(), "first line is in place")
  H.eq(r.result()[800], big[800]:upper(), "and so is the last, in order")
  local flat = {}
  for _, c in ipairs(pbig.calls) do
    vim.list_extend(flat, c)
  end
  H.eq(table.concat(flat, "\n"), table.concat(big, "\n"), "blocks together are exactly the input")

  -- an input that fits goes straight through (same job, no wrapping effects) -----
  local pfit = fake({ max_bytes = 1000 })
  local rf = run(pfit, { "a", "b" })
  H.eq(#pfit.calls, 1, "small input: one provider call")
  H.eq(rf.result()[2], "B", "result is the provider's")

  -- a failing block fails the whole call, cb once -----------------------------
  local pfail = fake({ max_bytes = 10 }, function(lines, cb, n)
    if n == 2 then
      cb(false, "HTTP 429")
    else
      cb(true, lines)
    end
  end)
  local rfail = run(pfail, { "aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff" })
  H.falsy(rfail.ok(), "a failed block fails the call")
  H.contains(rfail.result(), "HTTP 429", "with the provider's message")
  H.contains(rfail.result(), "block 2/", "and the block that failed")
  H.eq(rfail.calls(), 1, "cb exactly once")
  H.eq(#pfail.calls, 2, "later blocks are not sent")

  -- a provider that throws is reported, not raised -----------------------------
  local pending
  local pthrow = fake({ max_bytes = 10 }, function(lines, cb, n)
    if n == 2 then
      error("spawn exploded")
    end
    pending = function()
      cb(true, lines)
    end
    return { cancel = function() end }
  end)
  local rthrow_calls, rthrow_ok, rthrow_msg = 0, nil, nil
  local okcall = pcall(function()
    chunk.wrap(pthrow).translate({ "aaaa", "bbbb", "cccc", "dddd" }, "DE", nil, {}, function(o, m)
      rthrow_calls, rthrow_ok, rthrow_msg = rthrow_calls + 1, o, m
    end)
    pending() -- block 1 finishes; sending block 2 throws
  end)
  H.ok(okcall, "a throwing provider does not raise out of the wrapper")
  H.falsy(rthrow_ok, "it fails the call")
  H.contains(rthrow_msg, "spawn exploded", "with the error text")
  H.eq(rthrow_calls, 1, "once")

  -- a single over-long line: a clear message, provider never called -----------------
  local plong = fake({ max_bytes = 10 })
  local rlong = run(plong, { "ok", string.rep("z", 30) })
  H.falsy(rlong.ok(), "an unsplittable line fails the call")
  H.contains(rlong.result(), "line 2", "naming the line")
  H.contains(rlong.result(), "fake", "and the engine")
  H.eq(#plong.calls, 0, "without spawning anything")
  H.eq(rlong.calls(), 1, "cb exactly once")

  -- cancel() mid-run stops the active block and sends no further ones -------------
  local pending_cb, cancelled_jobs = nil, 0
  local pcancel = fake({ max_bytes = 10 }, function(_, cb, _)
    pending_cb = cb
    return {
      cancel = function()
        cancelled_jobs = cancelled_jobs + 1
      end,
    }
  end)
  local rc = run(pcancel, { "aaaa", "bbbb", "cccc", "dddd" })
  H.eq(#pcancel.calls, 1, "the first block is in flight")
  rc.job.cancel()
  H.eq(cancelled_jobs, 1, "cancel() cancels the running block")
  pending_cb(true, { "AAAA", "BBBB" })
  H.eq(#pcancel.calls, 1, "a late result does not start the next block")
  H.eq(rc.calls(), 0, "and the callback is dropped, like a cancelled job")

  -- asynchronous blocks complete in order -------------------------------------------
  local queue = {}
  local pasync = fake({ max_bytes = 10 }, function(lines, cb)
    queue[#queue + 1] = function()
      cb(true, vim.tbl_map(string.upper, lines))
    end
    return { cancel = function() end }
  end)
  local ra = run(pasync, { "aaaa", "bbbb", "cccc", "dddd" })
  H.eq(ra.calls(), 0, "nothing is delivered before the blocks finish")
  while #queue > 0 do
    table.remove(queue, 1)()
  end
  H.ok(ra.ok(), "all blocks done: success")
  H.eq(table.concat(ra.result(), ","), "AAAA,BBBB,CCCC,DDDD", "joined in order")
  H.eq(ra.calls(), 1, "cb exactly once")

  -- limits_for(): an engine's own config may raise its budget ------------------------
  local pov = fake({
    max_bytes = 100,
    override = function(c)
      return c.custom and c.custom.max_bytes
    end,
  })
  H.eq(chunk.limits_for(pov, {}).max_bytes, 100, "no engine config: the declared budget")
  H.eq(
    chunk.limits_for(pov, { custom = { max_bytes = 5000 } }).max_bytes,
    5000,
    "the engine's own option can raise it"
  )
  H.eq(
    chunk.limits_for(pov, { custom = { max_bytes = 5000 }, max_chars = 40 }).max_bytes,
    40,
    "translate.max_chars still lowers whatever applies"
  )

  -- blank lines at a block edge survive an engine that trims them ----------------------
  -- gtx drops leading/trailing newlines of the whole text, `trans -b` output is
  -- right-trimmed, the documented custom parse `vim.split(out, "\n")` adds one
  -- trailing "" of its own. The block cut prefers a blank line, so without the
  -- wrapper's edge handling every cut loses a line (and indent.restore() then
  -- skips the whole range, and TranslateReplace glues paragraphs together).
  ---@param limits table
  ---@param trailing? boolean   -- append "\n" before splitting, like `vim.split(out .. "\n", ...)`
  local function trimming(limits, trailing)
    local p = { name = "trim", limits = limits, calls = {} }
    p.available = function()
      return true
    end
    p.translate = function(lines, _t, _s, _c, cb)
      p.calls[#p.calls + 1] = lines
      local text = table.concat(lines, "\n"):upper():gsub("^%s+", ""):gsub("%s+$", "")
      if trailing then
        text = text .. "\n"
      end
      cb(true, vim.split(text, "\n", { plain = true }))
      return { cancel = function() end }
    end
    return p
  end

  local doc = {
    "alpha one",
    "alpha two",
    "",
    "beta one",
    "beta two",
    "",
    "gamma one",
    "",
    "",
    "delta one",
    "delta two",
  }
  local doc_up = vim.tbl_map(string.upper, doc)
  local doc_blocks = chunk.split(doc, { max_bytes = 30 })
  local cuts_on_blank = 0
  for _, b in ipairs(doc_blocks) do
    if doc[b.last] == "" then
      cuts_on_blank = cuts_on_blank + 1
    end
  end
  H.ok(cuts_on_blank > 0, "fixture: at least one block ends on a blank line")

  local ptrim = trimming({ max_bytes = 30 })
  local rtrim = run(ptrim, doc)
  H.ok(rtrim.ok(), "the chunked document is translated")
  H.eq(#rtrim.result(), #doc, "the line count is preserved against an engine that trims")
  H.eq(
    table.concat(rtrim.result(), "\n"),
    table.concat(doc_up, "\n"),
    "blank separators stay in place"
  )
  for _, c in ipairs(ptrim.calls) do
    H.falsy(c[1]:match("^%s*$"), "no block is sent with a leading blank line")
    H.falsy(c[#c]:match("^%s*$"), "nor with a trailing one")
  end

  local ptrail = trimming({ max_bytes = 30 }, true)
  local rtrail = run(ptrail, doc)
  H.eq(#rtrail.result(), #doc, "a parse that appends a trailing empty line does not add lines")
  H.eq(table.concat(rtrail.result(), "\n"), table.concat(doc_up, "\n"), "and nothing moves")

  -- the single-block path has the same trimming problem (selection ending in a blank line)
  local psingle = trimming({ max_bytes = 1000 })
  local rsingle = run(psingle, { "", "a", "b", "", "" })
  H.eq(table.concat(rsingle.result(), "|"), "|A|B||", "edges of a single block are put back too")
  H.eq(table.concat(psingle.calls[1], "|"), "a|b", "and were not sent")

  -- a block that is blank throughout is not sent at all
  local pblank = fake({ max_bytes = 10 })
  local rblank = run(pblank, { "aaaa", "", "", "", "", "", "", "bbbb" })
  H.ok(rblank.ok(), "blank runs in the middle are fine")
  H.eq(#rblank.result(), 8, "all lines come back")
  for _, c in ipairs(pblank.calls) do
    H.falsy(table.concat(c, ""):match("^%s*$"), "no provider call carries only blank lines")
  end
  local plone = fake({ max_bytes = 1000 })
  local rlone = run(plone, { "" })
  H.eq(#plone.calls, 0, "a lone blank line is not sent")
  H.eq(#rlone.result(), 1, "and comes back as one line (not as an empty list)")
  H.eq(rlone.result()[1], "", "unchanged")

  -- an over-long line is cut at sentence/word boundaries and stays ONE line ------------
  local prose =
    "First sentence is here. Second sentence follows it! Third one asks why? Fourth ends the line."
  local plong2 = fake({ max_bytes = 40 })
  local rlong2 = run(plong2, { "head", prose, "tail" })
  H.ok(rlong2.ok(), "an over-long line no longer fails the call")
  H.eq(#rlong2.result(), 3, "the line count is unchanged")
  H.eq(rlong2.result()[1], "HEAD", "the line before is in place")
  H.eq(rlong2.result()[2], prose:upper(), "the pieces are re-joined with a single space")
  H.eq(rlong2.result()[3], "TAIL", "the line after is in place")
  H.ok(#plong2.calls > 2, "the long line went out in several pieces")
  for _, c in ipairs(plong2.calls) do
    for _, l in ipairs(c) do
      H.ok(#l + 1 <= 40, "every piece fits the budget")
    end
  end
  for _, c in ipairs(plong2.calls) do
    H.ok(not (#c > 1 and c[1] == "head"), "pieces never share a block with other lines")
  end

  local words = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda"
  local pwords = fake({ max_bytes = 20 })
  local rwords = run(pwords, { words })
  H.ok(rwords.ok(), "a line without sentence ends is cut at white space")
  H.eq(#rwords.result(), 1, "one line out")
  H.eq(rwords.result()[1], words:upper(), "words intact")

  local jp = string.rep("これは文章です。", 20)
  local pjp = fake({ max_bytes = 100 })
  local rjp = run(pjp, { jp })
  H.ok(rjp.ok(), "CJK text without any white space is cut after the full stop")
  H.eq(#rjp.result(), 1, "one line out")
  H.eq(rjp.result()[1]:gsub(" ", ""), jp, "the characters are intact")
  for _, c in ipairs(pjp.calls) do
    for _, l in ipairs(c) do
      H.eq(l:sub(-3), "。", "no piece is cut inside a UTF-8 character")
    end
  end

  local pml = fake({ max_bytes = 30, max_lines = 2 })
  local rml = run(pml, { "aaaa bbbb cccc. dddd eeee ffff. gggg hhhh iiii. jjjj kkkk llll." })
  H.ok(rml.ok(), "pieces honour max_lines too")
  for _, c in ipairs(pml.calls) do
    H.ok(#c <= 2, "at most two pieces per block")
  end
  H.eq(#rml.result(), 1, "still one line")

  local ptok = fake({ max_bytes = 10 })
  local rtok = run(ptok, { "ok", string.rep("z", 30) })
  H.falsy(rtok.ok(), "a single token over the budget is still an error")
  H.contains(rtok.result(), "line 2", "that names the line")
  H.eq(#ptok.calls, 0, "before anything is sent")

  -- translate.max_blocks refuses an input that needs too many requests ------------------
  local six = { "aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff" }
  local pcap = fake({ max_bytes = 10 })
  local rcap = run(pcap, six, { max_blocks = 2 })
  H.falsy(rcap.ok(), "three requests are more than max_blocks = 2")
  H.contains(rcap.result(), "translate.max_blocks", "the message names the option")
  H.eq(#pcap.calls, 0, "nothing is sent")
  H.eq(rcap.calls(), 1, "cb exactly once")
  local pcap3 = fake({ max_bytes = 10 })
  H.ok(run(pcap3, six, { max_blocks = 3 }).ok(), "exactly max_blocks requests are fine")
  local pcap0 = fake({ max_bytes = 10 })
  H.ok(run(pcap0, six, { max_blocks = 0 }).ok(), "0 = no limit")
  H.eq(
    require("language.config.DEFAULTS").translate.max_blocks,
    50,
    "the shipped default caps one call at 50 requests"
  )

  -- a single request reports the engine's message as it is (no block prefix) ------------
  local pone = fake({ max_bytes = 1000 }, function(_, cb)
    cb(false, "HTTP 429")
    return nil
  end)
  local rone = run(pone, { "a", "b" })
  H.eq(rone.result(), "HTTP 429", "no 'block 1/1' decoration for a single request")

  -- Rules that were unpinned until a mutation run -----------------------------------------
  -- Every assertion in the sections below fails when the rule it names is deleted or bent in
  -- chunk.lua (checked by running this spec against hand-made mutants of the module). The
  -- fixtures are small on purpose: a tiny budget makes the boundary cases exact.
  --
  -- Mutants that cannot be killed because they do not change behaviour (a differential fuzz of
  -- 60 000 random inputs found no difference for any of them):
  --   * `return ws` instead of `ws - 1` in pick_boundary: the white space ends up in the piece
  --     and rtrim_ws removes it again;
  --   * dropping `stop <= n` in pick_boundary: the head is n + 1 bytes, so a sentence end that is
  --     followed by white space inside it is always at most n;
  --   * dropping the `math.min(.., max_bytes)` in fit(): only the upper bound of a binary search;
  --   * `while e > 1` in rtrim_ws, `lo < hi` in text_span, dropping the `n > 0` guard, the
  --     `stop >= len` break in split_line or the `#group > 0` guard in pack_pieces: each is
  --     redundant with a check right next to it.

  ---@param bl table[]
  ---@return string  -- a plain block as `first-last`, a piece block as `<line>p<pieces>`
  local function shape(bl)
    local out = {}
    for _, b in ipairs(bl) do
      out[#out + 1] = b.pieces and ("%dp%d"):format(b.first, #b.pieces)
        or ("%d-%d"):format(b.first, b.last)
    end
    return table.concat(out, " ")
  end

  ---@param bl table[]
  ---@return string  -- how many pieces each block carries, e.g. "3,3,1"
  local function per_block(bl)
    local out = {}
    for _, b in ipairs(bl) do
      out[#out + 1] = tostring(#(b.pieces or {}))
    end
    return table.concat(out, ",")
  end

  ---The pieces one over-long line is cut into, joined with "|".
  ---@param line string
  ---@param limits table
  ---@return string   -- "ERR <message>" when the line cannot be cut
  local function cut(line, limits)
    local bl, e = chunk.split({ line }, limits)
    if not bl then
      return "ERR " .. e
    end
    local all = {}
    for _, b in ipairs(bl) do
      vim.list_extend(all, b.pieces or {})
    end
    return table.concat(all, "|")
  end

  -- limits_for(): what an engine's override and max_chars may and may not do -----------------
  do
    local function const(v)
      return function()
        return v
      end
    end
    local function budget(override)
      return chunk.limits_for(fake({ max_bytes = 100, override = override }), {}).max_bytes
    end
    H.eq(budget(const(0)), 100, "an override of 0 is not a budget")
    H.eq(budget(const(-5)), 100, "nor is a negative one")
    H.eq(budget(const("5000")), 100, "nor a string")
    H.eq(
      budget(function()
        error("override exploded")
      end),
      100,
      "an override that throws leaves the declared budget"
    )
    H.eq(budget(const(5000.9)), 5000, "a fractional override is rounded down")
    H.eq(
      chunk.limits_for(fake({ max_bytes = 100 }), { max_chars = 40.7 }).max_bytes,
      40,
      "a fractional max_chars is rounded down too"
    )

    local carried = chunk.limits_for(
      fake({
        max_bytes = 100,
        max_lines = 50,
        cost = function(line)
          return #line + 8
        end,
      }),
      {}
    )
    H.eq(carried.max_lines, 50, "the engine's max_lines reaches the splitter")
    H.eq(carried.cost("abc"), 11, "and so does its cost function")
  end

  -- a cut prefers a blank line, but only in the second half of the block ----------------------
  do
    local early = chunk.split(
      { "a", "", "bbbbbb", "cccccc", "dddddd", "eeeeee" },
      { max_bytes = 25 }
    )
    H.eq(
      shape(early),
      "1-5 6-6",
      "a blank line in the first half of the block is not worth a short block"
    )

    local two = { "x", "x", "x", "x", "", "x", "", "x", "x" }
    H.eq(
      shape(chunk.split(two, { max_bytes = 15 })),
      "1-7 8-9",
      "of two blank lines in the second half the LAST one ends the block"
    )
  end

  -- block structure around an over-long line: no empty blocks, nothing stale left over --------
  do
    local long = "aaaa bbbb cccc dddd eeee"
    local exact = chunk.split({ "aaaaaaaaa" }, { max_bytes = 10 })
    H.eq(shape(exact), "1-1", "a line that costs exactly the budget is an ordinary block")
    H.eq(exact[1].pieces, nil, "it is not cut into pieces")

    H.eq(shape(chunk.split({ long }, { max_bytes = 10 })), "1p1 1p1 1p1", "a long first line")
    H.eq(
      shape(chunk.split({ "aaaa", "bbbb", long, "cccc", "dddd" }, { max_bytes = 10 })),
      "1-2 3p1 3p1 3p1 4-5",
      "lines before and after a long line form blocks of their own, with a fresh budget"
    )
    H.eq(
      shape(chunk.split({ "aaaa", long }, { max_bytes = 10 })),
      "1-1 2p1 2p1 2p1",
      "a long last line"
    )
    H.eq(
      shape(chunk.split({ string.rep(" ", 50), "x" }, { max_bytes = 10 })),
      "1-1 2-2",
      "an over-long blank line is an ordinary (blank) block, not a piece list"
    )

    local pws = fake({ max_bytes = 10 })
    local rws = run(pws, { string.rep(" ", 50), "x", string.rep("\t", 20) })
    H.ok(rws.ok(), "blank over-long lines do not fail the call")
    H.eq(#pws.calls, 1, "only the line with text is sent")
    H.eq(pws.calls[1][1], "x", "and it is sent alone")
    H.eq(rws.result()[1], string.rep(" ", 50), "the blank line comes back untouched")
    H.eq(rws.result()[2], "X", "the text line is translated")
    H.eq(rws.result()[3], string.rep("\t", 20), "a tab-only line too")
  end

  -- an over-long line is cut exactly where the doc says ----------------------------------------
  do
    H.eq(
      cut("aaaa bbbb cccc dddd", { max_bytes = 10 }),
      "aaaa bbbb|cccc dddd",
      "a piece may cost exactly the budget (and the byte after it is looked at)"
    )
    H.eq(
      cut("xxxxxxxxx yyyyyyyyy", { max_bytes = 10 }),
      "xxxxxxxxx|yyyyyyyyy",
      "a remainder that exactly fits is the last piece, not an unsplittable token"
    )

    for _, p in ipairs({ ".", "!", "?", ";" }) do
      H.eq(
        cut(("alpha beta gamma%s delta epsilon zeta eta"):format(p), { max_bytes = 25 }),
        ("alpha beta gamma%s|delta epsilon zeta eta"):format(p),
        ("'%s' ends a sentence: the cut is after it, not at the last blank"):format(p)
      )
    end
    H.eq(
      cut("One. Two three. four five six seven eight", { max_bytes = 25 }),
      "One. Two three.|four five six seven|eight",
      "of several sentence ends in range the LAST one wins"
    )
    H.eq(
      cut("123456789. abcdefghi jklmnopqr stuvwx", { max_bytes = 21 }),
      "123456789.|abcdefghi jklmnopqr|stuvwx",
      "a sentence end at exactly half the budget is taken"
    )
    H.eq(
      cut("12345678. abcdefghij klmn opqr", { max_bytes = 21 }),
      "12345678. abcdefghij|klmn opqr",
      "a sentence end one byte short of half loses against the last blank"
    )
    H.eq(
      cut("a xxxxxxxxxxxxxxxxxxx", { max_bytes = 21 }),
      "a|xxxxxxxxxxxxxxxxxxx",
      "a one-letter word in front of a long token is cut off at the blank"
    )

    local lead = cut("   alpha beta gamma delta epsilon zeta", { max_bytes = 20 })
    H.eq(
      lead,
      "alpha beta gamma|delta epsilon zeta",
      "white space in front of a line, and at a cut, is dropped"
    )
    H.eq(
      cut("word" .. string.rep(" ", 50) .. "word", { max_bytes = 20 }),
      "word|word",
      "a long run of blanks is one separator"
    )
  end

  -- trailing white space is stripped from a piece, nothing else is -----------------------------
  do
    local stem = string.rep("word ", 8)
    for name, tail in pairs({
      space = " ",
      tab = "\t",
      newline = "\n",
      vtab = "\v",
      formfeed = "\f",
      cr = "\r",
      mixed = " \t \r",
    }) do
      H.eq(
        cut(stem .. "end" .. tail, { max_bytes = 20 }):match("[^|]*$"),
        "end",
        "a trailing " .. name .. " is not sent to the engine"
      )
    end
    for _, byte in ipairs({ 8, 14 }) do
      H.eq(
        cut(stem .. "end" .. string.char(byte), { max_bytes = 20 }):match("[^|]*$"),
        "end" .. string.char(byte),
        ("byte %d is not white space and stays"):format(byte)
      )
    end
  end

  -- CJK: every sentence mark and every clause mark ends a piece ---------------------------------
  do
    local limits = { max_bytes = 40 } -- 39 bytes per piece: three 12-byte units fit
    for _, mark in ipairs({ "。", "！", "？", "；", "｡", "．" }) do
      local unit = "あいう" .. mark
      H.eq(
        cut(string.rep(unit, 8), limits),
        string.rep(unit, 3) .. "|" .. string.rep(unit, 3) .. "|" .. string.rep(unit, 2),
        ("'%s' is a sentence mark"):format(mark)
      )
    end
    for _, mark in ipairs({ "，", "、", "：", "､" }) do
      local unit = "あいう" .. mark
      H.eq(
        cut(string.rep(unit, 8), limits),
        string.rep(unit, 3) .. "|" .. string.rep(unit, 3) .. "|" .. string.rep(unit, 2),
        ("'%s' is a clause mark: the last resort when there is no sentence end and no blank"):format(
          mark
        )
      )
    end

    local jp_text = string.rep("これは文章です。", 20) -- sentences of 24 bytes
    local at_limit = chunk.split({ jp_text }, { max_bytes = 97 })
    H.eq(
      per_block(at_limit),
      "1,1,1,1,1",
      "a mark that ends exactly at the budget (96 of 96 bytes) is taken: four sentences a piece"
    )
    H.eq(#at_limit[1].pieces[1], 96, "the first piece is four sentences long")
    local past_limit = chunk.split({ jp_text }, { max_bytes = 96 })
    H.eq(#past_limit, 7, "a mark that ends one byte past the budget is not taken")
    H.eq(#past_limit[1].pieces[1], 72, "so the pieces are three sentences long")

    H.eq(
      cut("ab cd. あいうえおかきくけ。さしすせそ", { max_bytes = 40 }),
      "ab cd. あいうえおかきくけ。|さしすせそ",
      "a CJK mark later than an ASCII sentence end wins"
    )
    H.eq(
      cut("あいう。abc def ghi. jkl mno pqr stu", { max_bytes = 40 }),
      "あいう。abc def ghi.|jkl mno pqr stu",
      "an ASCII sentence end later than a CJK mark wins"
    )
    H.eq(
      cut("あ。" .. string.rep("いう，", 6), { max_bytes = 40 }),
      "あ。|いう，いう，いう，いう，|いう，いう，",
      "any sentence end beats a clause mark, even an early one"
    )
    H.eq(
      cut(string.rep("あ", 40), { max_bytes = 40 }),
      "ERR line 1 is too long to translate (121, limit 40): "
        .. "no sentence or word boundary inside the budget",
      "CJK without any mark has no boundary to cut at"
    )
  end

  -- an unsplittable token: the message says why --------------------------------------------------
  do
    local _, e = chunk.split({ "ok", string.rep("z", 30) }, { max_bytes = 10 })
    H.contains(
      e,
      "line 2 is too long to translate (31, limit 10)",
      "the line, its cost and the limit"
    )
    H.contains(e, "no sentence or word boundary inside the budget", "and the reason")
  end

  -- packing the pieces of one line into requests -----------------------------------------------
  do
    -- Words spread over a gap that is wider than the budget: every word is a piece of its own
    -- (the gap is dropped at the cut), so many tiny pieces can share one request.
    local function spread(count, gap)
      local letters = {}
      for i = 1, count do
        letters[i] = string.char(96 + i)
      end
      return table.concat(letters, string.rep(" ", gap))
    end

    local seven = spread(7, 8)
    local free = chunk.split({ seven }, { max_bytes = 6 })
    H.eq(per_block(free), "3,3,1", "three pieces of cost 2 fill a budget of 6 exactly")
    H.ok(free[#free].tail, "only the last block of a line is flagged as its tail")
    H.falsy(free[1].tail, "the first one is not")
    H.eq(
      per_block(chunk.split({ seven }, { max_bytes = 6, max_lines = 2 })),
      "2,2,2,1",
      "max_lines caps the pieces of one request"
    )
    H.eq(
      per_block(chunk.split({ seven }, { max_bytes = 6, max_lines = 3 })),
      "3,3,1",
      "and a cap that is exactly met is fine"
    )
    H.eq(
      per_block(chunk.split({ seven }, { max_bytes = 6, max_lines = 1 })),
      "1,1,1,1,1,1,1",
      "a cap of one request line each"
    )

    local deepl_loaded = package.loaded["language.translate.providers.deepl"]
    local deepl = require("language.translate.providers.deepl").limits
    package.loaded["language.translate.providers.deepl"] = deepl_loaded
    H.eq(deepl.max_lines, 50, "fixture: DeepL takes at most 50 texts per request")

    -- A DeepL-like engine at a budget of 500 bytes: 130 words, each further apart than a
    -- request is wide, are 130 pieces of cost 9, and 55 of them would fit by bytes alone.
    local many = {}
    for i = 1, 130 do
      many[i] = "w"
    end
    local wide = table.concat(many, string.rep(" ", 520))
    H.eq(
      per_block(chunk.split({ wide }, { max_bytes = 500, cost = deepl.cost })),
      "55,55,20",
      "fixture: without max_lines more than 50 pieces would share a request"
    )
    local pdeepl = fake(vim.deepcopy(deepl))
    local rdeepl = run(pdeepl, { wide }, { max_chars = 500 })
    H.ok(rdeepl.ok(), "a line of 130 pieces is translated")
    local sizes, costs_ok = {}, true
    for _, c in ipairs(pdeepl.calls) do
      sizes[#sizes + 1] = #c
      local used = 0
      for _, l in ipairs(c) do
        used = used + deepl.cost(l)
      end
      costs_ok = costs_ok and used <= 500
    end
    H.eq(table.concat(sizes, ","), "50,50,30", "no request carries more than 50 texts")
    H.ok(costs_ok, "and none exceeds the byte budget")
    H.eq(#rdeepl.result(), 1, "the line is still one line")
    H.eq(
      rdeepl.result()[1],
      table.concat(vim.fn.split(string.rep("W ", 130), " "), " "),
      "re-joined in order, every piece present"
    )

    -- budget by the cost function, not by bytes: two pieces of cost 10 fill a budget of 20
    local by_len = { max_bytes = 20, cost = string.len }
    H.eq(
      per_block(chunk.split({ string.rep("abcdefghi. ", 4) }, by_len)),
      "2,2",
      "a custom cost is what is summed (two 10-byte pieces fill 20 exactly)"
    )

    -- end to end through the wrapper: max_lines = 1 sends every piece alone
    local pone_each = fake({ max_bytes = 25, max_lines = 1 })
    local rone_each = run(pone_each, { string.rep("a", 15) .. string.rep(" ", 10) .. "bbbbb" })
    H.ok(rone_each.ok(), "a line cut at a wide gap is translated")
    H.eq(#pone_each.calls, 2, "max_lines = 1: two pieces, two requests")
    H.eq(#pone_each.calls[1], 1, "one text in the first")
    H.eq(rone_each.result()[1], string.rep("A", 15) .. " BBBBB", "joined with a single space")
    local pshare = fake({ max_bytes = 25 })
    run(pshare, { string.rep("a", 15) .. string.rep(" ", 10) .. "bbbbb" })
    H.eq(#pshare.calls, 1, "fixture: without max_lines both pieces share one request")
  end

  -- wrap(): what the callers can rely on around the engine call ------------------------------
  do
    local plain = {
      name = "plain",
      available = function()
        return true
      end,
      translate = function() end,
    }
    H.eq(chunk.wrap(plain), plain, "a provider that declares no limits is returned as it is")

    local pempty = fake({ max_bytes = 10 })
    local rempty = run(pempty, {})
    H.eq(#pempty.calls, 1, "an empty input still reaches the engine")
    H.eq(#rempty.result(), 0, "and the engine's answer is returned")

    H.eq(
      rfail.result(),
      "block 2/3 (lines 3-4): HTTP 429",
      "a failed block is named by its number and its lines"
    )

    local whole = { "a", "b" }
    local pwhole = fake({ max_bytes = 1000 })
    run(pwhole, whole)
    H.eq(pwhole.calls[1], whole, "a request that is the whole input is handed over without a copy")

    local pstring = fake({ max_bytes = 1000 }, function(_, cb)
      cb(true, "not a list")
      return nil
    end)
    local rstring = run(pstring, { "a" })
    H.falsy(rstring.ok(), "an engine that answers with something else than lines fails the call")
    H.contains(rstring.result(), "returned no lines", "and says so")
    H.eq(rstring.calls(), 1, "once")

    -- the pieces of each over-long line are re-joined on their own
    local long = "aaaa bbbb cccc dddd eeee"
    local rtwice = run(fake({ max_bytes = 10 }), { long, "mid", long })
    H.eq(#rtwice.result(), 3, "three lines in, three out")
    H.eq(rtwice.result()[1], long:upper(), "the first long line is whole again")
    H.eq(rtwice.result()[2], "MID", "the line between is untouched")
    H.eq(
      rtwice.result()[3],
      long:upper(),
      "and the second one holds none of the first one's pieces"
    )

    -- a piece the engine translates to nothing leaves no gap
    local pgap = fake({ max_bytes = 10 }, function(lines, cb, n)
      local out = {}
      for i, l in ipairs(lines) do
        out[i] = n == 2 and "" or l:upper()
      end
      cb(true, out)
      return nil
    end)
    H.eq(
      run(pgap, { long }).result()[1],
      "AAAA BBBB EEEE",
      "an empty translation of a piece is skipped, not joined as a double space"
    )

    -- surplus lines in an answer: only blank ones go, and never more than the surplus
    local function answering(result)
      return fake({ max_bytes = 1000 }, function(_, cb)
        cb(true, result)
        return nil
      end)
    end
    local rblank_last = run(answering({ "A", "" }), { "a", "..." })
    H.eq(
      table.concat(rblank_last.result(), "|"),
      "A|",
      "a line the engine translated to nothing is a line, not a surplus"
    )
    local rsurplus = run(answering({ "A", "", "" }), { "a", "." })
    H.eq(table.concat(rsurplus.result(), "|"), "A|", "one surplus blank line is dropped, not two")
    local rtext = run(answering({ "A", "B", "C" }), { "a", "b" })
    H.eq(table.concat(rtext.result(), "|"), "A|B|C", "surplus text is never silently dropped")

    -- a misbehaving engine that calls back twice
    local pdouble = fake({ max_bytes = 1000 }, function(_, cb)
      cb(true, { "A", "B" })
      cb(true, { "X", "Y" })
      return nil
    end)
    local rdouble = run(pdouble, { "a", "b" })
    H.eq(rdouble.calls(), 1, "cb exactly once")
    H.eq(
      table.concat(rdouble.result(), ","),
      "A,B",
      "a second answer does not touch the delivered result"
    )

    -- cancel(): the request in flight, and nothing that raises
    local cancelled_now = { 0, 0 }
    local pafter_sync = fake({ max_bytes = 10 }, function(lines, cb, n)
      if n == 1 then
        cb(true, lines) -- answers before translate() has even returned
      end
      return {
        cancel = function()
          cancelled_now[n] = cancelled_now[n] + 1
        end,
      }
    end)
    local rafter_sync = run(pafter_sync, { "aaaa", "bbbb", "cccc", "dddd" })
    rafter_sync.job.cancel()
    H.eq(cancelled_now[2], 1, "cancel() reaches the request that is in flight")
    H.eq(cancelled_now[1], 0, "and not the one that had already answered")

    local pcancel_throws = fake({ max_bytes = 10 }, function()
      return {
        cancel = function()
          error("cancel exploded")
        end,
      }
    end)
    local rthrows = run(pcancel_throws, { "aaaa", "bbbb", "cccc", "dddd" })
    H.ok(pcall(rthrows.job.cancel), "a cancel that throws does not raise out of the wrapper")
    local pno_job = fake({ max_bytes = 10 }, function()
      return nil
    end)
    local rno_job = run(pno_job, { "aaaa", "bbbb", "cccc", "dddd" })
    H.ok(pcall(rno_job.job.cancel), "cancel() with no job behind it is fine")

    -- a call that is already settled or cancelled stays quiet, whatever the engine does next
    local plate = fake({ max_bytes = 1000 }, function(lines, cb)
      cb(true, vim.tbl_map(string.upper, lines))
      error("died after answering")
    end)
    local rlate = run(plate, { "a" })
    H.eq(rlate.calls(), 1, "an engine that answers and then throws is reported once")
    H.ok(rlate.ok(), "with the answer it gave")

    local resume, victim = nil, nil
    local pdies = fake({ max_bytes = 10 }, function(lines, cb, n)
      if n == 1 then
        resume = function()
          cb(true, lines)
        end
        return nil
      end
      victim.job.cancel()
      error("died while being cancelled")
    end)
    victim = run(pdies, { "aaaa", "bbbb", "cccc", "dddd" })
    resume()
    H.eq(victim.calls(), 0, "a cancelled call stays silent, even when the engine dies afterwards")

    -- the failure of the second of two requests carries its position
    local pfail2 = fake({ max_bytes = 10 }, function(lines, cb, n)
      cb(n ~= 2, n == 2 and "HTTP 500" or lines)
      return nil
    end)
    H.eq(
      run(pfail2, { "aaaa", "bbbb", "cccc", "dddd" }).result(),
      "block 2/2 (lines 3-4): HTTP 500",
      "two requests are already worth saying which one failed"
    )

    -- configuration that cannot be used degrades to "no limit" instead of raising
    H.eq(
      chunk.limits_for(fake({ max_bytes = 100 }), nil).max_bytes,
      100,
      "no config at all: the declared budget"
    )
    H.eq(chunk.limits_for(pov, nil).max_bytes, 100, "an override that cannot read it is ignored")
    local rnil_cfg
    local wrapped_nil = chunk.wrap(fake({ max_bytes = 10 }))
    wrapped_nil.translate({ "aaaa", "bbbb", "cccc" }, "DE", nil, nil, function(_, got)
      rnil_cfg = got
    end)
    H.eq(table.concat(rnil_cfg, ","), "AAAA,BBBB,CCCC", "translate() without a config table works")
    for _, junk in ipairs({ "2", true, -1 }) do
      H.ok(
        run(fake({ max_bytes = 10 }), six, { max_blocks = junk }).ok(),
        ("max_blocks = %s is not a cap"):format(tostring(junk))
      )
    end
    H.contains(rcap.result(), "needs 3 requests", "the max_blocks message counts the requests")
    H.contains(rcap.result(), "translate.max_blocks (2)", "and names the cap")
  end

  -- pause between blocks, deadline for the whole call, line-count warning ---------------
  -- The keyless gtx endpoint answers a burst with HTTP 429: the blocks of one call go out
  -- with `limits.pause_ms` between them (`translate.block_pause_ms` replaces it), a call
  -- can be bounded as a whole (`translate.deadline_ms`), and a block whose engine merged
  -- or split lines is reported instead of being passed on silently.
  do
    local ppause = fake({ max_bytes = 100, pause_ms = 300 })
    H.eq(chunk.limits_for(ppause, {}).pause_ms, 300, "the engine's pause is the default")
    H.eq(chunk.limits_for(ppause, { block_pause_ms = 0 }).pause_ms, 0, "0 turns it off")
    H.eq(chunk.limits_for(ppause, { block_pause_ms = 25 }).pause_ms, 25, "the option replaces it")
    H.eq(
      chunk.limits_for(ppause, { block_pause_ms = -1 }).pause_ms,
      300,
      "a negative value is no pause"
    )
    H.eq(chunk.limits_for(fake({ max_bytes = 100 }), {}).pause_ms, 0, "no engine pause: none")

    local six3 = { "aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff" }
    local pwait = fake({ max_bytes = 10, pause_ms = 40 })
    local t0 = vim.uv.hrtime()
    local rwait = run(pwait, six3)
    H.eq(#pwait.calls, 1, "the next block waits for the pause")
    H.eq(rwait.calls(), 0, "nothing is delivered yet")
    H.ok(
      vim.wait(2000, function()
        return rwait.calls() > 0
      end, 5),
      "the call completes after the pauses"
    )
    local elapsed = (vim.uv.hrtime() - t0) / 1e6
    H.eq(#pwait.calls, 3, "every block is sent")
    H.ok(rwait.ok(), "success")
    H.eq(table.concat(rwait.result(), ","), "AAAA,BBBB,CCCC,DDDD,EEEE,FFFF", "joined in order")
    H.eq(rwait.calls(), 1, "cb exactly once")
    H.ok(elapsed >= 75, ("two pauses of 40 ms between three blocks (%.0f ms)"):format(elapsed))

    local poff = fake({ max_bytes = 10, pause_ms = 40 })
    local roff = run(poff, six3, { block_pause_ms = 0 })
    H.eq(#poff.calls, 3, "block_pause_ms = 0: all blocks go out right away")
    H.eq(roff.calls(), 1, "and the call is done synchronously")

    local pone1 = fake({ max_bytes = 100, pause_ms = 40 })
    local rone1 = run(pone1, { "a", "b" })
    H.eq(rone1.calls(), 1, "a single block is never delayed")

    local pcp = fake({ max_bytes = 10, pause_ms = 30 })
    local rcp = run(pcp, six3)
    H.eq(#pcp.calls, 1, "first block sent, pause pending")
    rcp.job.cancel()
    vim.wait(120)
    H.eq(#pcp.calls, 1, "cancel during the pause sends no further block")
    H.eq(rcp.calls(), 0, "and drops the callback")

    -- deadline_ms: the request in flight is cancelled, the call fails once
    local stuck_cb, stuck_cancels = nil, 0
    local pstuck = fake({ max_bytes = 10 }, function(_, cb)
      stuck_cb = cb
      return {
        cancel = function()
          stuck_cancels = stuck_cancels + 1
        end,
      }
    end)
    local rdl = run(pstuck, six3, { deadline_ms = 40 })
    H.ok(
      vim.wait(2000, function()
        return rdl.calls() > 0
      end, 5),
      "the deadline ends a call that hangs"
    )
    H.falsy(rdl.ok(), "as a failure")
    H.contains(rdl.result(), "translate.deadline_ms (40 ms)", "naming the option")
    H.contains(rdl.result(), "0 of 3 blocks done", "and how far it got")
    H.eq(stuck_cancels, 1, "the request in flight is cancelled")
    stuck_cb(true, { "AAAA", "BBBB" })
    H.eq(#pstuck.calls, 1, "a late result starts no further block")
    H.eq(rdl.calls(), 1, "and is not delivered")

    local pquick = fake({ max_bytes = 10 })
    local rq = run(pquick, six3, { deadline_ms = 30 })
    H.ok(rq.ok(), "a call that finishes in time is not touched")
    vim.wait(80)
    H.eq(rq.calls(), 1, "the deadline timer is gone once the call settled")

    -- the deadline can strike in the pause after a block: that block counts as done, and
    -- its finished request (answered synchronously) is not cancelled again
    local pp_cancels = 0
    local ppd = fake({ max_bytes = 10, pause_ms = 500 }, function(lines, cb)
      local up = {}
      for i, l in ipairs(lines) do
        up[i] = l:upper()
      end
      cb(true, up)
      return {
        cancel = function()
          pp_cancels = pp_cancels + 1
        end,
      }
    end)
    local rpd = run(ppd, six3, { deadline_ms = 40 })
    H.ok(
      vim.wait(2000, function()
        return rpd.calls() > 0
      end, 5),
      "the deadline ends the call during the pause"
    )
    H.falsy(rpd.ok(), "as a failure")
    H.contains(rpd.result(), "1 of 3 blocks done", "counting the block before the pause")
    H.eq(pp_cancels, 0, "the answered request is not cancelled")
    local rpc = run(ppd, six3)
    rpc.job.cancel()
    H.eq(pp_cancels, 0, "nor by a cancel during the pause")
    H.eq(rpc.calls(), 0, "which drops the callback")

    -- a block with another line count is reported once the call succeeds
    local real_notify = vim.notify
    local warnings = {}
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warnings[#warnings + 1] = msg
      end
    end
    local pmerge = fake({ max_bytes = 10 }, function(lines, cb, n)
      if n == 2 then
        cb(true, { table.concat(lines, " ") }) -- the engine merged the two lines
      else
        cb(true, lines)
      end
    end)
    local rmerge = run(pmerge, six3)
    local pmerge1 = fake({ max_bytes = 100 }, function(lines, cb)
      cb(true, { table.concat(lines, " ") })
    end)
    local rmerge1 = run(pmerge1, { "a", "b" })
    local psame = fake({ max_bytes = 10 })
    run(psame, six3)
    vim.notify = real_notify
    H.ok(rmerge.ok(), "a merged block still delivers the result")
    H.eq(#rmerge.result(), 5, "with the line the engine merged away")
    H.eq(#warnings, 1, "one warning for the call (single-block call and matching counts: none)")
    H.contains(warnings[1] or "", "block 2/3 (lines 3-4)", "naming the block and its lines")
    H.contains(warnings[1] or "", "1 lines for 2 sent", "and both counts")
    H.ok(rmerge1.ok(), "a single block passes its own result through")
  end

  -- registry: every engine is wrapped ---------------------------------------------------
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate.providers.google"] = nil
  local runs, stdins = {}, {}
  local real_job = package.loaded["language.util.job"]
  package.loaded["language.util.job"] = {
    run = function(argv, opts)
      runs[#runs + 1] = argv
      stdins[#stdins + 1] = opts.stdin
      opts.on_done(true, '[[["x","y"]]]', "")
      return { cancel = function() end }
    end,
  }
  local registry = require("language.translate.providers.registry")
  local google = registry.get("google")
  local g_lines = {}
  for i = 1, 1200 do
    g_lines[i] = ("line %04d "):format(i) .. string.rep("a", 60)
  end
  local gdone, gok, gres = 0, nil, nil
  -- no pause between the blocks here: this section runs the blocks synchronously; the
  -- stub answers one line per block, so the line-count warning is expected and muted
  local notify_before = vim.notify
  local g_warned = 0
  vim.notify = function()
    g_warned = g_warned + 1
  end
  google.translate(g_lines, "DE", nil, { block_pause_ms = 0 }, function(o, rr)
    gdone, gok, gres = gdone + 1, o, rr
  end)
  vim.notify = notify_before
  H.eq(g_warned, 1, "the merged lines of the stub are reported once")
  H.ok(#runs > 1, "google through the registry: the input is split into several requests")
  for _, argv in ipairs(runs) do
    for _, a in ipairs(argv) do
      H.ok(#a < 32700, "no argv element comes near the Windows limit")
    end
  end
  for _, body in ipairs(stdins) do
    H.ok(#body <= 15000, "every request body stays within the google budget")
  end
  H.eq(gdone, 1, "cb exactly once")
  H.ok(gok, "success")
  H.eq(#gres, #runs, "one translated segment per block here, joined in order")

  -- google: single long lines (unwrapped markdown paragraphs, CJK) no longer fail ------
  -- Before the body moved to stdin the budget was the percent-encoded length 5000:
  -- a ~3 600 character prose line or a 600 character Japanese line was refused.
  local echo_runs = {}
  package.loaded["language.util.job"] = {
    run = function(argv, opts)
      echo_runs[#echo_runs + 1] = { argv = argv, stdin = opts.stdin }
      opts.on_done(true, vim.json.encode({ { { (opts.stdin or ""):upper() } } }), "")
      return { cancel = function() end }
    end,
  }
  -- the providers hold the job module they were loaded with: load them afresh
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate.providers.google"] = nil
  registry = require("language.translate.providers.registry")
  ---@param line string
  ---@return table result, integer requests
  local function google_one(line)
    echo_runs = {}
    local res
    registry.get("google").translate({ line }, "DE", nil, { block_pause_ms = 0 }, function(o, got)
      res = { ok = o, result = got }
    end)
    return res, #echo_runs
  end

  local prose36 = string.rep("word ", 720):gsub(" $", "")
  local g1, n1 = google_one(prose36)
  H.ok(g1.ok, "a 3 600 character prose line is translated")
  H.eq(n1, 1, "in one request")
  H.eq(g1.result[1], prose36:upper(), "unchanged by the engine's echo")

  local jp600 = string.rep("これは文章です。", 75)
  local g2, n2 = google_one(jp600)
  H.ok(g2.ok, "a 600 character Japanese line is translated")
  H.eq(n2, 1, "in one request")

  local huge = string.rep("The quick brown fox jumps over the lazy dog. ", 900):gsub(" $", "")
  local g3, n3 = google_one(huge)
  H.ok(g3.ok, "a 40 000 byte single line is translated too")
  H.ok(n3 > 1, "in several requests")
  H.eq(#g3.result, 1, "and still comes back as one line")
  H.eq(g3.result[1], huge:upper(), "re-joined without losing a word")
  for _, req in ipairs(echo_runs) do
    H.ok(#req.stdin <= 15000, "each piece fits the request budget")
  end

  -- google: a rate limit or an HTML page is named as such, not "invalid response" ---------
  do
    local answer, seen_argv
    package.loaded["language.util.job"] = {
      run = function(argv, opts)
        seen_argv = argv
        opts.on_done(true, answer, "")
        return { cancel = function() end }
      end,
    }
    package.loaded["language.translate.providers.google"] = nil
    local graw = require("language.translate.providers.google")
    H.eq(graw.limits.pause_ms, 300, "google pauses between the blocks of one call by default")
    ---@param out string
    ---@return table
    local function gtx(out)
      answer = out
      local res
      graw.translate({ "Hallo" }, "EN", nil, {}, function(o, got)
        res = { ok = o, result = got }
      end)
      return res
    end
    local ok200 = gtx('[[["Hello","Hallo"]]]\n200')
    H.ok(ok200.ok, "a JSON answer with status 200 is translated")
    H.eq(ok200.result[1], "Hello", "the status line is not part of the text")
    H.ok(vim.tbl_contains(seen_argv, "-w"), "curl is asked for the HTTP status")
    H.ok(gtx('[[["Hello","Hallo"]]]').ok, "an answer without a status line still parses")
    local r429 = gtx("<html><body>Too Many Requests</body></html>\n429")
    H.falsy(r429.ok, "HTTP 429 fails the request")
    H.contains(r429.result, "rate limited", "naming the rate limit")
    H.contains(r429.result, "HTTP 429", "and the status")
    local r503 = gtx("Service Unavailable\n503")
    H.contains(r503.result, "HTTP 503", "another error status is named")
    local rhtml = gtx("<!DOCTYPE html><html>sorry</html>\n200")
    H.falsy(rhtml.ok, "an HTML page instead of JSON fails")
    H.contains(rhtml.result, "HTML page", "and says what came back")
  end

  -- Surviving mutants of the first mutation run (see the list of unkillable ones above) -------

  -- 1. White-space-only lines (spaces, tabs) at a block edge are layout like empty ones: an
  --    engine that trims them must not lose them, and they are never sent. Every separator
  --    below is a different kind of white space, so a BLANK that only knows "" fails here.
  do
    local ws_doc = {
      "alpha one",
      "alpha two",
      "  ",
      "beta one",
      "beta two",
      "\t",
      "gamma one",
      " \t ",
      "",
      "delta one",
      "delta two",
    }
    local ws_up = vim.tbl_map(string.upper, ws_doc)
    local ws_blocks = chunk.split(ws_doc, { max_bytes = 30 })
    local ws_edges = 0
    for _, b in ipairs(ws_blocks) do
      if ws_doc[b.last]:match("^%s+$") then
        ws_edges = ws_edges + 1
      end
    end
    H.ok(ws_edges > 0, "fixture: a block ends on a white-space-only line")

    local pws = trimming({ max_bytes = 30 })
    local rws_run = run(pws, ws_doc)
    H.ok(rws_run.ok(), "a document with white-space-only separators is translated")
    H.eq(#rws_run.result(), #ws_doc, "the line count is preserved against an engine that trims")
    H.eq(
      table.concat(rws_run.result(), "\n"),
      -- upper() of white space is itself: the separators come back byte for byte
      table.concat(ws_up, "\n"),
      "the white-space separators stay exactly as they were"
    )
    for _, c in ipairs(pws.calls) do
      H.falsy(c[1]:match("^%s*$"), "no block is sent with a white-space-only first line")
      H.falsy(c[#c]:match("^%s*$"), "nor with a white-space-only last line")
    end

    -- blank throughout (only spaces and tabs): not sent at all, lines kept as they are
    local pall = fake({ max_bytes = 1000 })
    local rall = run(pall, { " ", "\t", "  " })
    H.eq(#pall.calls, 0, "white-space-only lines alone are not sent")
    H.eq(table.concat(rall.result(), "|"), " |\t|  ", "and come back untouched")
  end

  -- 2. `limits.cost` decides the budget in split(), in the cut of an over-long line (fit) and
  --    in the packing of its pieces. A cost that doubles the bytes makes every one of them
  --    visible; the default cost (bytes + 1) would pack and cut differently.
  do
    local doubled = function(line)
      return #line * 2
    end
    local bl = chunk.split({ "aaaa", "bbbb", "cccc", "dddd" }, { max_bytes = 10, cost = doubled })
    H.eq(#bl, 4, "split(): cost 8 per line under a budget of 10 is one line per block")
    local plain = chunk.split({ "aaaa", "bbbb", "cccc", "dddd" }, { max_bytes = 10 })
    H.eq(#plain, 2, "(without a cost function the same lines pair up)")

    local long = "word word word word word"
    local pieces = chunk.split({ long }, { max_bytes = 12, cost = doubled })
    H.ok(pieces and #pieces == 5, "fit(): the line is cut into the five words the cost allows")
    for k, b in ipairs(pieces or {}) do
      H.eq(#b.pieces, 1, ("pack_pieces(): piece block %d holds one piece (cost 8 of 12)"):format(k))
      H.ok(doubled(b.pieces[1]) <= 12, "every piece fits the budget in cost units")
    end
  end

  -- 3. A clause mark (CJK comma) is a cut only when it ENDS inside the budget: the head handed
  --    to the picker is the budget plus one byte, and a mark that ends on that extra byte is
  --    over the budget. Budget 11 -> a piece of at most 10 bytes ("，" is 3 bytes).
  do
    local inside = chunk.split({ "aaaaaaa，bbb" }, { max_bytes = 11 })
    H.ok(inside ~= nil, "a clause mark ending exactly at the budget is a boundary")
    H.eq(
      table.concat(
        vim.tbl_map(function(b)
          return table.concat(b.pieces, "|")
        end, inside or {}),
        ";"
      ),
      "aaaaaaa，;bbb",
      "and the line is cut right after it"
    )
    local beyond, beyond_err = chunk.split({ "aaaaaaaa，bbb" }, { max_bytes = 11 })
    H.ok(beyond == nil, "a clause mark ending one byte past the budget is no boundary")
    H.contains(
      beyond_err or "",
      "no sentence or word boundary",
      "so the line is refused, not cut inside it"
    )
  end

  package.loaded["language.util.job"] = real_job
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate.providers.google"] = nil
end
