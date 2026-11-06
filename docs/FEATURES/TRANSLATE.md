# Translate

Translating text with a choice of engines and output destinations, none of
which require an external Neovim plugin — only `curl` for the default
keyless engine.

## `:Translate` / `:TranslateReplace`

`:Translate` translates a range/selection and, by default, shows the
result in a read-only, focusable `ui.kit` popup — the buffer
stays untouched. `--output=` selects an alternative destination:
`replace`/`buffer`/`vsplit`/`split`/`tab`/`insert`/`clipboard`/`notify`.
`:TranslateReplace` is the direct, mutating counterpart — always
`replace`, no `--output=` flag — restoring the classic "select, translate,
replace" workflow under its own name. `--nocode` skips fenced code blocks
and every line that holds inline code (relevant to replace-style output of a
text scope only; `cwd`, `path=<p>` and `cword` ignore it).
If the translated lines change while the request is running (`replace`, `insert`,
`--nocode`), the result is discarded and the buffer stays as it is; with `--nocode`
that holds for all ranges at once.

- **Tab:** true
- **Module:** `translate/init.lua`, `translate/output/init.lua`
- **Usercmds:** `:Translate <lang> [--nocode|--output=<m>|--files=<m>] [cword|selection|buffer|visible|cwd|path=<p>]`, `:TranslateReplace <lang> [--nocode] [selection|buffer|visible|cwd|path=<p>]` — [user commands](../BINDINGS.md#user-commands)
- **One word:** the `cword` scope, and — with hover.nvim installed — `:Hover show` over a word. See [HOVER.md](HOVER.md).
- **Config:** `opts.translate.default_output` (default `"popup"`), `opts.translate.engine` (default `"google"`)

An unrecognized `--flag` is now a reported error (composer's declared-flags
gate runs before the handler), not silently ignored as it was
pre-composer.

## Engines with fallback chain

Google (keyless `gtx` endpoint, default, zero configuration), DeepL
(`deepl.api_key` or `$DEEPL_API_KEY`), `translate-shell`, or a custom CLI —
`opts.translate.fallback` is an ordered list tried if the selected engine
is unavailable **or its request fails**.

What the chain means:

- The chain is `engine` followed by `fallback`, minus duplicates and engines that
  are unavailable (no key, no `curl`, ...). Nothing outside it is ever tried: the
  text only goes to engines you wrote down yourself. The default `fallback = { "google" }`
  therefore changes nothing; add `"deepl"` or `"shell"` to get a second engine.
- A request that fails (timeout, HTTP error such as the 429 of the keyless Google
  endpoint, a page instead of JSON) moves the whole call on to the next engine of the
  chain. A hint names the engine that answered; if every engine fails, only the last
  error is reported.
- No switch for an error in the input itself (a line that cannot be cut, more requests
  than `translate.max_blocks`), for a cancel, and never away from the `ai` engine (a
  policy refusal is final). `translate_markdown` uses the first available engine only:
  its unit cache is keyed by the engine that translated. A call with `engine = ...`
  has no fallback chain at all.

- **Module:** `translate/providers/{google,deepl,shell,ai,custom,registry}.lua`
- **Config:** `opts.translate.engine`, `opts.translate.fallback` (default `{"google"}`), `opts.translate.deepl.api_key`

### Large inputs: chunking

Windows rejects a command line above roughly 32 700 characters
(`ENAMETOOLONG`), and the engines have limits of their own, so no provider
ever receives an arbitrarily large payload. `providers/registry.lua` wraps
every engine with `translate/chunk.lua`, which cuts the input into blocks on
line boundaries (preferring blank lines), translates them one after the
other through the unchanged provider and joins the results; the line count
is preserved, which the indent restoration relies on. This applies to the
command, the operators, the window, the hover and multi-file translation.

The budget is counted in **cost units**, which are bytes of the text plus one
per line for the separator -- except DeepL, which counts 8 extra per line for
the JSON quoting of each text. This is the unit of `translate.max_chars`.

| Engine | Block budget (cost units) | Payload |
| --- | --- | --- |
| google | 15 000 | POST body on stdin (`--data-urlencode q@-`): neither in the URL nor in argv |
| shell | 6000 on Windows, 20 000 elsewhere | stdin, never argv (a `trans.cmd` shim runs through `cmd.exe /c`); `trans` translates it line by line, one request per non-empty line, and `translate.timeout_ms` is granted per such line |
| custom | same as shell; `translate.custom.max_bytes` replaces it | whatever `cmd` builds; a `stdin` field of the returned argv goes to the process on stdin |
| deepl | 50 lines, 60 000 | key **and** JSON body on stdin (`curl -K -`), never argv |

- **Blank lines at the edge of a block are layout, not content.** The engines
  trim them (gtx drops leading and trailing newlines, `trans` output is
  right-trimmed, a custom `vim.split(out, "\n")` adds a trailing empty
  string), so they are not sent and are put back around the result; a block
  that is blank throughout is not sent at all. Without this every cut at a
  paragraph break would lose a line and merge two paragraphs.
- **A single line over the budget is cut, not refused.** It is split at
  sentence ends (`. ! ? ;` before white space, and the CJK `。！？；`), else at
  white space, never inside a UTF-8 character; the pieces are translated in
  blocks of their own and re-joined with a single space, so the input line
  stays one output line. Only a line that has no such boundary inside the
  budget (one giant token, e.g. minified JSON or base64) fails the call, with
  a message naming the line.
- `opts.translate.max_chars` (cost units, `0` = engine default) can only lower
  the budget; `opts.translate.custom.max_bytes` is the one way to raise the
  `custom` budget, for a `cmd` that does not put the text into argv.
- `opts.translate.max_blocks` (default `50`, `0` = no limit) refuses an input
  that would need more requests than that, before the first one is sent, with
  a message naming the option. A large buffer or file is otherwise fired off
  request by request (the keyless gtx endpoint rate-limits), and everything
  sent before a late failure has already left the machine.
- `opts.translate.timeout_ms` applies to **each request**, not to the whole
  call: a chunked input can take up to `blocks * timeout_ms`.
  `opts.translate.deadline_ms` (default `0` = none) bounds the whole call: when
  it runs out, the request in flight is cancelled and the call fails with a
  message naming the option and how many blocks were done.
- `opts.translate.block_pause_ms` is the pause between two requests of one
  call. `nil` (the default) takes the engine's own: `300` ms for `google` and
  `shell` (both use the keyless endpoint, which answers a burst with HTTP 429),
  `0` for the others; `0` turns it off.
- A rate limit is named as such: `google` reads the HTTP status (`curl -w`) and
  reports HTTP 429, another non-2xx status or an HTML page instead of JSON
  plainly, and the call stops at that block.
- A block that comes back with another line count than was sent (the engine
  merged or split lines) is reported with a warning naming the block and its
  lines once the call succeeds; the lines after it are shifted.
- A failing block fails the whole call (one callback, with the block and
  line range in the message); `cancel` stops the running block, a pending
  pause and the rest.
- `util/job.run` reports a spawn failure through `on_done(false, ...)`
  instead of throwing, and `translate.files.process` turns a failure into a
  failed file while the remaining files carry on.
- **Windows launchers that are not `.exe`** (an npm-style or `.cmd`/`.bat`
  shim for `trans` or a custom engine) are started through `cmd.exe /c`, and
  its parser would interpret a `"`, `%`, `^`, `&`, `|`, `<`, `>` or line break
  inside the translated text. `util/job.run` refuses such a command with a
  message instead of running it; use an `.exe` for the engine (or one of the
  curl-based engines) to translate arbitrary text.

## Markdown API: `translate_markdown`

```lua
local handle = require("language").translate_markdown(lines, opts, function(ok, result, info)
  -- ok == true:  result is string[], exactly #lines long; info is the report
  -- ok == false: result is a message ("cancelled", "stale", "no available translate engine ...")
end)
handle.cancel() -- optional; the callback then runs once with (false, "cancelled")
```

Translates a whole Markdown document and gives back **exactly as many lines as
it got** (`#result == #lines`, a hard invariant: when an internal check ever
disagrees, the original comes back). It is the engine behind a translated
preview: the buffer stays German, the previewer shows English, and every
line-based mapping of the previewer (scroll sync, cursor marker,
click-to-navigate) stays valid because no line moves.

Not a command: there is no `:Translate` flag for it. It is for Lua callers
(mdview.nvim is the first).

### Options

| Option | Meaning |
| --- | --- |
| `target` | **Required.** Target language, e.g. `"EN"`. |
| `source` | Source language; `nil` lets the engine detect it. |
| `engine` | Overrides `translate.engine` for this call (no fallback chain). |
| `model` | Part of the cache key. The `ai` engine adds its own identity (provider, model, prompt version, glossary/style) on top, so a model switch needs nothing here. |
| `token` | `{ generation, current = fn }` (or `{ cancelled = true }`): the run is abandoned, `cb(false, "stale")`, once `current() ~= generation`. |
| `max_chars` | Bytes of masked text per request (default `translate.markdown.max_chars`, 3000). |
| `max_units` | Units per request (default 40; DeepL accepts 50 texts). |
| `concurrency` | Requests in flight (default `translate.markdown.concurrency`, 3). |
| `keep` | Words that are never translated (proper names), added to `translate.markdown.keep`. |
| `cache` | `false` bypasses the cache (read and write). |
| `slice_ms` | Length of one slice of CPU work before the event loop gets a turn (default 8). Without it, a small document (under 2 000 lines, under 64 kB and under an estimated 30 ms of work, see below) is not sliced at all; with it, any document is. `0` hands the control back at every interruption point (what the specs use to prove that the result does not depend on where the work is cut). |
| `cache_only` | Never asks the engine: a cached unit is translated, every other stays original, `info.pending` counts them. The building block for stale-while-revalidate: show this at once, then run again without it. |
| `on_unit` | `fun(ev)`: called once per finished block with `{ first, last, lines, status, done, total }`. `lines` replaces source lines `first..last` (same count). Progressive filling: patch the view as events arrive, finish with the `result` of `cb`. `status` is `"translated"`, `"cached"` or `"partial"`. A reference definition is no block, so its rewritten anchor target only appears in the final result. |

Every callback runs on the main loop and never before `translate_markdown` has
returned. `cb` runs **exactly once**, also after `cancel()`, a stale token or an
internal error (also one thrown while an answer of the engine is booked: `cb(false, "translate_markdown: ...")`).

**Big documents.** Segmenting, masking, the cache pass, the anchor map and the final reflow and
render are CPU work in plain Lua (about 0.5 s for 20 000 lines, 0.1 to 0.5 ms per kB of text).
From 2 000 lines or 64 kB on, or as soon as an estimate of the work reaches about 30 ms, they run in
slices of about 8 ms (`slice_ms`). The estimate counts lines, bytes and pipes (each one can be a
table cell, and a cell is a unit of its own): a table of 65 kB with 9 000 cells is about 100 ms, a
list of 1 999 items about 45 ms, 63 kB of long paragraphs 5 ms (measured; the weights err on the
high side). Measured on a development machine: a list item with code and a link costs about 30
microseconds, a plain item 21, a table cell 6, a byte 0.1 to 0.4; 1 999 lines of 2.5 kB are 1.9 s.
The three limits are `SLICE_MIN_LINES`, `SLICE_MIN_BYTES` and `SLICE_COST_LIMIT` in
`lua/language/translate/markdown/init.lua`; the estimate stays under about 30 ms of work, below what
a keystroke can notice. What stays below is a few tens of milliseconds and is translated in one go. The work is
a coroutine that gives the control back at line, unit and heading boundaries, and a zero-delay timer continues it,
so redraws, keys and timers keep running in between (40 000 lines: the loop is never blocked for
more than a frame or two). The same goes for booking an answer of the engine that stands for
more than 256 units (all its entries together; many identical units are many reports), and for
booking the units of entries that failed (an error, an invalid answer, the rest given up after
repeated failures). The result does not depend on the cuts. The callback contract holds across the
gaps: `cb` once, never before the call returned, and a cancel or a stale token is noticed before
every slice, after which nothing is continued and no engine is asked. A single unit (one
paragraph of a megabyte) gives way inside, too: the scan of the mask, the placeholder check and
`unmask` of its answer, the normalisation and syntax check of that answer, and the reflow call the
interruption point every 256 steps (`slice.every`). An answer of more than 64 kB is validated and
booked in a coroutine of its own (`SLICE_ANSWER_BYTES`). Measured: one line of 1 MB of mixed
inline syntax blocked the loop for 300 to 700 ms at a time before, 15 to 40 ms now; what is left is
the segmenter's look at that one line (about 30 ms).

The order of the `on_unit` events and of `info.errors` is the order in which the work finished,
and the gaps of a slice let answers of the engine arrive in between: a sliced run can report the
same blocks in another order than an unsliced one (the content of every event and the result are
the same). Guaranteed: one event per changed block, `done` counts 1..`total` in the order of the
calls, a block with a link to a heading is reported after the anchor map exists, and the blocks
that waited for the map come before the block of the heading that completed it. One exception,
`cache_only`: a block that links to a heading whose translation is not in the cache is returned
translated (it counts as `cached`, the heading as `pending`), but it gets no event, because the
anchor map is never completed.

`info` is the report: `units`, `translated`, `cached`, `failed` (stayed
original after validation and retry), `skipped` (nothing to translate),
`pending` (`cache_only`), `reflow_failed`, `requests`, `retries`,
`anchors_changed`, `anchor_collisions`, `errors` (the first few messages), `ms` and `slices` (how
often the CPU work handed the control back; 0 for a small document).

**Anchor collisions.** Links to a heading (`](#setup)`) follow the translated heading. When two
headings that had different anchors translate to the *same* one (`Setup` and `Installation` both
become `Setup`), the later one is numbered the way GitHub and markdown.nvim number repeated
headings (`#setup-1`), and a link to it is rewritten to that. That is right where the numbering is
known; a previewer that resolves only the first match would take the link to the first heading.
The numbering is kept (the alternative, leaving the second heading in the original language,
would mix languages in the output); `info.anchor_collisions` counts the cases and `info.errors`
names each, so the caller can say so.

### What is translated

Never translated, kept byte for byte: front matter (`---` opening with a `key:`
line, as the previewer reads it, or `+++`), fenced code (``` and `~~~`),
indented code, `$$` math blocks (only when a closing `$$` follows; a stray
`$$` is text), HTML blocks and comments, reference definitions (with the line
after a bare `[label]:`), thematic breaks, setext underlines, table delimiter
rows, blank lines. Translated, each as a unit of its own: headings,
paragraphs, list items, block quotes, footnote definitions and **every table
cell** (the pipes stay). A hard line break (two trailing spaces or a
backslash) ends a unit, since the reflow would move it; inside a code span that
runs over lines it is just text and does not.

The segmenter reads the document the way CommonMark does: a stack of open
containers (block quote, list item, footnote), and for every line (1) which
containers continue (a `>`, or indent up to the content column of the item; a
blank line keeps an item that holds a block), (2) whether an open fence, HTML
block or table goes on, (3) which blocks start here, inside the containers that
matched, and (4) what is left: a blank line, a lazy or ordinary continuation of
the paragraph, a table row, or a new paragraph. Columns are counted with tab
stops of four, so the content column of an item, "at most three columns of
indent" and "four columns are code" mean what they mean for the previewer. It
follows from the stack that a fence ends with its container, a block that
starts in the first column ends a list, an ordered list that does not start at
1 cannot interrupt a paragraph, a list item beats a table delimiter row, a
table header is the last line of the paragraph above it (and needs as many
cells as the delimiter row), and text indented to an outer item belongs to
that item. `$$` and `[label]:` lines are no blocks of their own, as in the
previewer: they stay as they are inside the paragraph they belong to (a block
start ends that paragraph and the math with it). CRLF endings count like LF.
Where it is unsure it prefers "literal" (German stays German) to "text".

Every scan is linear: the look-aheads of the masking work on a budget per unit,
and a unit that used it up (`mask.degraded`, a pathological run of brackets or
backticks) is not sent at all and stays as it is, rather than being translated
with syntax that was not protected. What does not look ahead is linear on its
own: the end of an address is found by a byte scan from its end (a
`gsub("[...]+$", "")` restarts at every byte of a run of punctuation), the end of
the run of non-blank bytes an address stands in is looked up once per run and
not once per `https://` in it, an HTML tag is matched by its first `>` with one
`find` (a pattern with a name class in front of `[^<>]*` backtracks over the
name), and the end of a footnote label is remembered. `TESTS/translate_markdown_mask_spec.lua`
runs each of these on a 40 000 byte line of the worst shape.

Inside a unit, inline code, link and image targets, autolinks, bare URLs and
e-mail / `www.` addresses (the previewer links them), inline HTML, entities, footnote references, `{#id}` attribute lists and the
`keep` words are **masked**: replaced by a placeholder, translated around, put
back afterwards. The text of a link stays translatable, except for an address
that is the text (or the end of it): `[https://example.com](https://example.com)`,
the commonest form in a README, is masked as `{1}{2}{3}`, so the engine cannot
rewrite the visible address. Collapsed and shortcut
references (`[text][]`, `[label]` with a definition) are masked whole, since
their text is their key.

The placeholder is plain ASCII, `{n}`. This is measured, not a taste: in the
spike (2026-10-06) the Unicode pair U+27E6/U+27E7 came back as `?1?` for 25 % of
the units on the Windows curl path. It reproduces on a current machine too: with
the text as one argv element, `curl` hands a loopback server `?1?` for the
Unicode pair and `{1}` for the ASCII one (and even `ü` arrives as the single
byte `%FC`, not UTF-8, which is why an argv-based `custom` engine is the weak
spot on Windows, while `google`, `deepl` and `shell` send stdin). See
[non-ASCII text on Windows](#non-ascii-text-on-windows) for the cause.
`TESTS/translate_markdown_curl_spec.lua` runs the whole pipeline through a real
curl and a loopback server to keep it that way.

### Never broken: validation, retry, fall back

Each answer is checked: every placeholder present exactly once (the halves of a
link in the right order; fullwidth braces and `{ 1 }` are put right first),
not empty, a plausible length compared with the source, and no link, image, HTML
tag or address (with a scheme, `www.` or an e-mail address) that the source did not
have (the targets of the source are
placeholders, so a model cannot be talked into adding a link or a tracking
image by the text of the document). The e-mail test is as wide as the
previewer's autolinker, which also links `_@x.example`, `+@x.example`, `.@x.example`
and `a@x_y.example` (the mask takes `_` in a domain label as well). The patterns (`](`, `][`,
a tag, `://`) are counted; the addresses are compared themselves: an address that the source
has and the mask leaves alone (`http://x` is too short, `xhttps://a.example` follows a word
character) may be kept, with other punctuation around it or in front of CJK text, but not
swapped for another one or repeated. The spelling that does not change the target is not a
swap: the scheme and the host in another case, the hex digits of a `%XX` escape in another
case and a lone trailing `/` (`FTP://Host.example` -> `ftp://host.example/`); the path is case
sensitive and stays as it is. An address is the ASCII run cut out of the text, so text
of a CJK target that follows it without a blank is not part of it (an address with non-ASCII
characters is compared up to the first one). A unit that fails is
retried once (a batch with an unattributable line count is retried unit by
unit); if it fails again, **the original unit stays**: the preview shows German
for that paragraph and is never empty or half. Three failed requests in a row
stop the run (a down engine or a 429 is not hammered); the document then comes
back as it was, with `info.failed` and `info.errors` telling why. A failed unit
is **never cached**: the spike saw 27 requests instead of 1 for a one-paragraph
change because failures had been remembered as answers.

### Reflow: the same number of lines

A unit's translation is wrapped onto exactly the line count of its source,
distributing the words in proportion to the width of the original lines. Soft
line breaks are invisible in the rendered HTML. **No break lands in front of a
word that Markdown reads as a block start**: `-`, `*`, `+`, `1.`, `#`, `>`,
`|`, a fence, a thematic break or setext underline, `<`, `$$`, `:::`, a
definition `[x]:`. The spike lost a sentence to a dash at the start of a line,
which became a list item (98 blocks turned into 102); the rule has a golden
test. The same check guards the first line of a paragraph, an item, a quote, a setext
heading and the first cell of a row that has no leading pipe, and a wrap that
would make a table delimiter row (`| --- | :-: |`) out of a line of text is
refused. A table cell is also refused when its translation has a pipe of its
own or ends in a backslash. If no safe break exists, the unit stays original
(`info.reflow_failed`).

Fewer words than lines (a short translation, or CJK without spaces): the words
take one line each and the surplus lines are padded: blank lines at the end of
a plain paragraph, a zero-width space (U+200B) line inside an item, a quote or
mid-paragraph, where a blank line would split the block or loosen the list.

### Anchors

Translating the heading `Installation` to `Setup` changes its slug, while the
masked target `(#installation)` does not: 16 of 18 table-of-contents links
broke in the spike. The i-th original heading's slug is mapped to the i-th
translated heading's slug and every `](#old)` target (and a `[x]: #old`
definition) is rewritten. The slug function is the one the mdview client
resolves anchors with, letter for letter (lower case; Unicode letters and
numbers, white space and hyphens only, so combining marks and symbols go; the
first heading with a slug wins); the heading text is read the way the previewer
reads it (an image contributes nothing, an autolink shows its address,
character references are decoded). A repeated slug is numbered `-1`, `-2`, as
GitHub and markdown.nvim number it, on both sides, so a generated table of
contents maps too. A target that matches no heading stays as it is. A unit
that stays as it is (nothing to translate, or its translation failed) still
gets its in-page links rewritten. Blocks that contain such a link are held back from `on_unit`
until the headings are known (headings are sent first).

### Cache

Key = hash of (engine, model, target, source, masked unit text); the value is
the validated translation with the placeholders still in it, so two units that
differ only in a link target share an entry. Memory is bounded (20 000 units);
an optional disk file (`stdpath("cache")/language.nvim/translate_markdown.json`,
through `lib.nvim.cache.disk`) is read lazily, written debounced after a change
and at exit, merged with what another Neovim wrote, and cut to
`translate.markdown.cache_max_kb` (oldest first). A damaged file or an entry of
the wrong shape is ignored, and a cached value goes through the same
placeholder check as a fresh answer. `require("language").translate_markdown_clear_cache({ disk = true })`
forgets everything. **Privacy:** the disk cache holds your translated text in
plain JSON; switch it off with `translate.markdown.disk_cache = false`.

### Requests

Units are deduplicated, then packed (headings first) into requests of at most
`max_chars` bytes and `max_units` units, `concurrency` of them in flight.
The request goes through the existing provider registry and its chunk wrapper,
so every engine's own limits apply on top. DeepL's `tag_handling` is **not**
used: the `{n}` placeholders need no tags, and the provider signature stays
unchanged.

Measured on a laptop with a fake engine (no network): a 1 460-line document of
619 units took 23 ms cold, 19 ms with every unit cached and 17 ms for a
one-paragraph change (one request, one unit). Real engines add their latency:
the spike measured 8-18 s for a cold 105-unit document with four parallel
single-unit requests and 48 s serially, which is why units are batched and the
cold start is meant to be shown progressively (`on_unit`) over the original.

### Config

```lua
translate = {
  markdown = {
    concurrency = 3,     -- requests in flight
    max_chars = 3000,    -- masked bytes per request
    disk_cache = true,   -- persist the unit cache in stdpath("cache")
    cache_max_kb = 2048, -- size cap of that file
    cache_dir = nil,     -- directory of that file instead of stdpath("cache")/language.nvim
    keep = {},           -- words that are never translated, e.g. { "Neovim" }
  },
}
```

- **Modules:** `translate/markdown/{init,segment,mask,reflow,anchors,unicode,cache}.lua`
- **Specs:** `translate_markdown_*_spec.lua` (golden documents in
  `TESTS/fixtures/markdown/`, a property test of the reflow, a fuzz run of the
  whole pipeline, the real-curl placeholder spec). The stall spec of the slicer
  (`translate_markdown_slice_spec.lua`) is half the size of its first version on purpose: that
  ran 21 to 29 s, nearly half of the 60 s a spec file may take, and the unsliced work of the
  halved document is still 8 times the limit the spec checks (400 ms for the mixed document).
  What a smaller document can no longer show in time is pinned by counting the ticks
  (`translate_markdown_slice_sites_spec.lua`, which also pins that a failed entry is booked in
  slices like an answer).
- **Oracle:** `scripts/markdown_oracle.lua` + `scripts/markdown_oracle.mjs`
  translate real Markdown files with a fake engine and compare source and
  result with the previewer's own renderer (comrak, from a sibling
  `mdview.nvim` checkout): block structure, literal blocks, link / image /
  code targets. Run it over a few hundred files after every change of the
  segmenter (`node scripts/markdown_oracle.mjs <dir>` exits 1 on a difference).
  `scripts/markdown_fuzz.lua <dir> [count] [seed] [wide]` writes random documents (fragments under random
  quote / list / tab containers) and a `list.txt` for the oracle: `markdown_oracle.lua <pairs> @<dir>/list.txt`.
  `wide` adds footnotes, open HTML blocks (`<pre>`, `<details>`, `<script>`), `$$` in lists, table variants,
  definitions with titles and odd markers. A raw `<pre>` that is never closed (or stands inline in a paragraph)
  swallows the Markdown rendered after it; the oracle reads the literal blocks from a second rendering with the
  source map on and leaves out what is rendered text there, so such a page is no false alarm any more.
  The container stack (2026-10-20) took the segmenter from 56 differing runs of 2 000 (1 000 documents) to none in
  20 000 random documents (four seeds of 5 000), and none in the real files of the repos. The wide set found five
  more kinds of case (container widths are relative to the container around them, a footnote ends at a line of one to
  three spaces, a header with another cell count than its delimiter row stays literal, a destination line is no
  list item, definitions below definitions at any indent), all fixed. With the honest `<pre>` check (2026-10-30) one
  more: a raw HTML block (`<script>`, `<pre>`, `<style>`, `<textarea>`) ends at any of the four end tags, not only
  at its own; the destination line of a bare `[label]:` in a quote is read without its quote markers (also a lazy
  one), and `-->` is a destination, no bullet. In the real files: a pipe right behind a backslash is no cell border,
  also behind an escaped backslash (`\\|`). A fourth seed added two: a task box with nothing behind it (`- [ ] `) is
  still the item's paragraph, and below a paragraph of nothing but definitions an underline (`===`, `---`) is text.
  After that: four seeds of 5 000 wide documents, 5 000 default ones and 1 500 real files, no difference.
  `node scripts/markdown_reduce.mjs <file.md>` shrinks a flagged file to the few lines that matter (it removes
  lines while the oracle still flags the result): the way each remaining difference was found.

Limits worth knowing: the Markdown parser reads blocks only and errs on the side
of skipping (code mistaken for prose is caught by the placeholder and length
checks; prose mistaken for code stays German); there is no inline parse for
emphasis, so `*`/`_` stay in the text for the engine to keep; math in single
`$...$` is not recognised.

## AI engine (`ai`, through ai.nvim)

`translate.engine = "ai"` translates through ai.nvim (Claude, Ollama, OpenAI,
Gemini ...). Terminology and tone hold over the whole document, and a local
model (Ollama) keeps the text on the machine. It costs latency and money and is
not deterministic, so the engine distrusts every answer.

- **Soft dependency.** ai.nvim is only `require`d when a request is made. The
  engine is available when ai.nvim loads and its policy admits the provider.
- **Request.** A system prompt (target, optional source, glossary, style;
  "code, identifiers, URLs, `{n}` placeholders and Markdown syntax unchanged,
  exactly the same number of elements") and the lines as a **JSON array**; the
  answer is a JSON array. It goes out through ai.nvim's bulk profile
  (`ai.ask({ bulk = ... })`, see ai.nvim's `docs/bulk.md`): request cap,
  concurrency, cumulative budget, temperature 0 where the provider has one.
- **Strict parse.** Valid JSON (one Markdown fence around the array is
  tolerated, any other text is not), an array, exactly as many elements as sent,
  all strings without a line break, and every `{n}` placeholder of an element
  present exactly as often as in the input. A deviation is asked once more, with the reason in the
  system prompt; a second deviation is an error to the caller. `translate_markdown`
  then keeps the original unit (and never caches it).
- **Policy.** Document text is stricter than a chat selection: a provider
  outside ai.nvim's allow-list is refused unless it was confirmed for bulk use
  (`require("ai.policy").grant_bulk("<id>")`); `allow_unlisted` and a
  `:Ai provider` confirmation do not count. Refusals and `bulk_limit` errors are
  shown with ai.nvim's message, are never retried and never routed to another
  engine. A configured `ai` engine that is unusable (ai.nvim missing, provider
  not allowed) is reported by the registry as an error and does **not** fall back
  to `google`: the text would otherwise reach a third party you did not choose.
  (`ai` further down the `fallback` list is simply skipped when unusable.)
- **Chunking.** The engine declares `limits` for the chunk wrapper: at most 60
  lines per request and `max_chars` minus the system prompt, counted as JSON.
  `translate.max_blocks` applies as for every engine.
- **Run label and budget.** Every `translate_markdown` call is one run, and so is
  every other translate call (its blocks share the run); all requests of a run
  share one bulk label, so `concurrency` and `max_total_chars` hold per run, however
  long a pause is in the middle. The next run starts a fresh label with a fresh
  `max_total_chars` budget, however close it follows.
  The old label is **not** reset: `bulk.reset(label)` would give its characters
  back to ai.nvim's session cap (`config.bulk.max_session_chars`), which must
  keep counting every run of the session.
- **Cancel.** `cancel()` kills the ai.nvim request and drops the callback. An
  already sent request cannot be aborted (ai.nvim): its answer is discarded.
- **Cache.** `cache_id` joins provider, model, prompt version and a hash of
  the system prompt (base text, glossary, style) into the `translate_markdown`
  cache key. Provider and model are the ones ai.nvim resolves for a request
  right now (`ai.providers.resolve`, then `translate.ai.model`, ai.nvim's
  `model[provider]`, the provider's default), so a switch of provider, model or
  provider order never serves old translations, also before the first answer
  and across sessions. Only where that cannot be told (a provider reachable
  through a bulk grant only) the `res.bulk.model` of the last answer is used.
- **ai.nvim version.** An ai.nvim without `ai.bulk` counts as not installed: it
  would ignore `req.bulk` and send the document as a plain chat request.

```lua
translate = {
  engine = "ai",
  ai = {
    provider = nil,          -- ai.nvim provider id; nil = ai.nvim's own choice
    model = nil,             -- nil = ai.nvim's configured model
    glossary = nil,          -- { Term = "Begriff" }, or { "Neovim" } (kept as is)
    style = nil,             -- tone, e.g. "formal, second person"
    max_chars = 6000,        -- largest request (prompt + system), characters
    concurrency = 2,         -- requests in flight per run
    max_total_chars = 500000,-- characters per run; false = no cap
  },
}
```

- **Module:** `translate/providers/ai.lua`
- **Spec:** `TESTS/translate_ai_provider_spec.lua` (fake `ai` module)
- **Health:** `:checkhealth language` shows the engine, provider/model and the policy.

## Custom translate provider

`translate.custom = { cmd = function(lines, target) return {"trans", "-b", ...} end, parse = function(out) return vim.split(out, "\n") end }` —
an escape hatch mirroring `spell.providers.custom`. `cmd` receives one block
of lines (see [chunking](#large-inputs-chunking)); a trailing empty entry in
what `parse` returns is dropped when the block has gained a line.

The argv `cmd` returns may carry a `stdin` field (a string). It is written to
the process and the pipe is closed; it is not part of the command line. Put
the text there whenever it can be non-ASCII and the program reads stdin:

```lua
cmd = function(lines)
  return {
    "curl", "-s", "-X", "POST", "--data-urlencode", "q@-", url,
    stdin = table.concat(lines, "\n"),
  }
end,
```

With the text on stdin, `max_bytes` can be raised as well (no command-line
limit applies).

- **Module:** `translate/providers/custom.lua`
- **Config:** `opts.translate.custom` (`cmd`, `parse`, optional `max_bytes`)
- **Spec:** `TESTS/translate_custom_stdin_curl_spec.lua` (real curl, loopback server)

### Non-ASCII text on Windows

Measured 2026-10-30 (Windows 11, Neovim 0.12): Neovim hands every argv element
to the child as exact UTF-8 (UTF-16 on the Windows command line). What the
child makes of it depends on how the program was built. A program with a
Unicode entry point (`C:\Windows\System32\curl.exe`, Neovim) gets the text
intact; one without it, such as the `curl.exe` of Git for Windows / MSYS2
(`mingw64/bin/curl.exe`), gets it converted to the ANSI code page: `ü`
becomes the single byte 0xFC, CJK and `⟦ ⟧` become `?`. The editor cannot
change the code page of another program, so the text has to bypass argv.

| Engine | Non-ASCII text on Windows |
| --- | --- |
| google, deepl | safe: the text goes to curl on stdin |
| shell | safe: the text goes to `trans` on stdin |
| ai | depends on ai.nvim's transport (not measured here) |
| custom | safe with the `stdin` field; text in an argv element depends on the program's build |

## Indent-preserving round trip

Each line's leading whitespace is captured before translating the dedented
text, then re-prepended to the matching output line — closes a gap where
providers (notably Google's `gtx`) normalize away leading whitespace,
which would otherwise drop indented list items to column 0. Skipped when
the provider merges or splits lines (line counts no longer match 1:1).

- **Module:** `translate/indent.lua`

## Column-precise selection

Char-wise motions (e.g. `<lhs>iw`) and char-wise visual selections
translate the exact byte span (multibyte-safe via `getregionpos`) and
replace it in place, rather than falling back to whole-line replacement.
Line-wise and block-wise selections still use the line range.

- **Module:** `translate/init.lua` (`run_region`)

## Motion/visual translate maps

Opt-in operator (`{lhs}{motion}` translates the moved-over text object,
e.g. `gtrip`) and visual-mode map (translates the current selection).
Target is `translate.default_target` if set, otherwise a quick picker.
Both always replace in place regardless of the popup default used by
`:Translate`.

- **Module:** `translate/motion.lua`
- **Config:** `opts.translate.keymaps.operator` (default `false`), `opts.translate.keymaps.visual` (default `false`), `opts.translate.keymaps.to` (default `{}`), `opts.translate.default_target`

### Choosing the target from the keymap (2026-08-24)

With `default_target` set the operator always used it and never asked;
without one it always asked. Neither is "translate this bit into Spanish,
just now" — the flag/option audit's entry.

`translate.keymaps.to` is one key per language:

```lua
translate = { keymaps = { to = { EN = "<leader>tE", DE = "<leader>tD" } } },
```

Each key works in normal (operator) and visual mode and forces that target
for a **single** run — the force is consumed by the next `choose_target`, so
it never leaks into the following unforced one.

A count could not carry the language: on an operator the count belongs to the
motion (`3{lhs}w` is three words), which is the whole point of having an
operator. Hence a key per language, which is what the audit suggested as well.
Unset by default.

- **Module:** `translate/motion.lua` (`force_target`, `choose_target`)

## Interactive translate window

`:Translate!` opens a two-pane float — editable input, live output —
that translates as you type. `<C-l>` retargets the language, `<C-y>`
copies the result, `<C-h>` opens the history picker, `<C-r>` promotes the
current translation to the input and picks a new target (round-trip/
reverse translation). `q`/`<Esc>`/`<C-c>` closes it. Prefilled from a
range/selection when given one (`:'<,'>Translate! DE`).

- **Module:** `translate/window.lua`
- **Usercmds:** `:Translate!` — [user commands](../BINDINGS.md#user-commands)

## Query history

Records `:Translate` results and window copies in a newest-first ring,
with optional JSON persistence across restarts. Recall via the window's
`<C-h>` picker or `require("language").translate_history()`.

- **Module:** `translate/history.lua`

## Multi-file translation

`:Translate <lang> cwd` (or `path=<dir>`) gathers translatable files under
the target, multi-selects via the `ui.kit` chooser (`<Tab>`), and
translates each — writing a language-suffixed sibling file by default
(`name.DE.ext`), overwriting in place with `--files=replace` (confirmed),
or opening scratch buffers with `--files=buffers`.
`:TranslateReplace <lang> cwd` forces file-mode `replace`.

The files offered are those with an extension of `translate.files.extensions`
and no larger than `translate.files.max_kb` (default `512` KB); `translate.files.output`
(`suffix`, `replace` or `buffers`) is the default for `--files=<mode>`.

`path=<p>` accepts a file or a directory (`~` and environment variables are
expanded). A single file (`path=README.md`) skips the chooser and is
translated the same way, with the same output modes; `:TranslateReplace`
asks before overwriting it. A path that does not exist is reported as an
error. The Lua API takes the same scopes:
`require("language").translate("DE", { scope = { kind = "path", path = "README.md" }, files = "buffers" })`
— `files` picks the output mode (default `translate.files.output`;
`translate_replace` forces `replace`).

- **Module:** `translate/files.lua`
- **Config:** `opts.translate.files.output`

## Office documents (PowerPoint, Word)

`:TranslateOffice <file> <lang>` translates a `.pptx` or `.docx` into a copy next to it
(`deck.pptx` → `deck.<lang>.pptx`); the original is never written. The file is a ZIP archive of XML: the text of
the slides and speaker notes (PowerPoint, tables included) or of the body, headers, footers and footnotes (Word)
goes through the configured translate engine and is put back at the same place, so formatting, pictures,
animations, masters, fields and numbering stay as they are.

- **One paragraph is one sentence.** A paragraph cut into runs (bold in the middle of a sentence) is sent as one
  text with a numbered placeholder `{k}` where a run ends, and split at those placeholders again. If an engine
  lost, doubled or reordered one, the whole text of that paragraph goes into its first run and the other runs
  become empty: no word is lost, the formatting of that one paragraph is. Placeholders in the form an engine
  likes to write them (`{ 1 }`, the fullwidth braces of CJK) are read as `{1}`.
- **Left alone:** paragraphs without a letter (numbers, dashes), a paragraph that contains a literal `{1}`,
  field instructions. Equal paragraphs are sent once. The engine is called in batches of 40 paragraphs, with the
  usual notice of that engine; nothing leaves the machine otherwise.
- **Safety:** the archive is read in Lua first (central directory) and refused before anything is unpacked when
  an entry leaves the folder (`../x`, `/x`, `C:x`, backslashes), is a link, the archive is ZIP64, has more than
  2 000 entries or unpacks to more than 200 MiB. Then `unzip`, `bsdtar` (`tar` on Windows and macOS; GNU tar
  cannot do ZIP and is skipped) or `7z` unpacks it into a temporary folder, `zip`, `bsdtar` or `7z` packs the
  copy. No tool, no translation, with a message saying so. Nothing of the file is run, macros included. The limits
  go by the sizes the archive declares. The copy is written beside its name first and moved into place when it is
  complete, so a failure or a cancel leaves no half archive; a copy of an earlier run under the same name is
  replaced by the new one. A file name with blanks is written in quotes: `:TranslateOffice "my deck.pptx" de`.
- **Lua:** `require("language.translate.office").translate_file(path, lang, opts, cb)`;
  `cb(ok, path_of_copy_or_reason)`, `opts.out`, `opts.on_progress(done, total)`.
- **Not yet:** `.xlsx`, `.odt`, text in charts and SmartArt, comments; a preview in mdview.nvim.

- **Module:** `translate/office/{init,xml,zip}.lua`
- **Usercmd:** `:TranslateOffice <file> <lang>`
