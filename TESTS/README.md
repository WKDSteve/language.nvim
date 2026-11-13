# TESTS/

Headless spec suite. Every spec drives a module directly — no picker, no
window, no external spell CLI, no network.

```
bash scripts/test.sh                  # every spec
bash scripts/test.sh --file config    # only spec files whose name contains "config"
bash scripts/test.sh --json ir.json   # also write the machine-readable result
```

The specs are run by [testing.nvim](https://github.com/WKDSteve/testing.nvim)
(configured in `.testing.lua`; dialect `h`, i.e. on this directory's own
`harness.lua`). Every `*_spec.lua` under `TESTS/` is discovered — there is no
list to maintain. Exit 0 is a pass; a failed spec, or a missing testing.nvim /
lib.nvim, exits 1 (and the script prints `LANGUAGE_TESTS_OK` on a green run).
CI runs exactly this command.

## testing.nvim and lib.nvim

Several modules require lib.nvim at module load, so the suite cannot run
without it. `scripts/test.sh` resolves testing.nvim and lib.nvim, each in
this order (a missing one is a loud error naming all four places):

1. `$TESTING_NVIM_DIR` / `$LIB_NVIM_DIR`
2. `.deps/<name>`
3. a sibling checkout, `../<name>`
4. the lazy.nvim-managed copy under `stdpath("data")/lazy/<name>`

A sibling wins over the plugin-manager copy on purpose: that one is often older
than the working checkout, and testing against a stale lib.nvim gives
misleading failures.

## The specs

| | |
| --- | --- |
| `split_spec.lua` | breaking an identifier into words a dictionary can be asked about — camelCase, acronyms, separators, and the offsets that turn a hit back into a highlight |
| `scope_spec.lua` | turning the words after a command into the region it acts on, and handing the caller's own arguments back |
| `ignore_spec.lua` | the session ignore set and the filter that applies it, plus the persistent list (redirected to a fixture file via `spell.dictionary.ignore_file`, never the developer's real one) |
| `actions_spec.lua` | `replace_all_in_buffer`'s whole-word boundary (not a substring match) and its empty-input/no-match paths, `add_to_dict`'s validation and its real `:spellgood` effect on `vim.spell.check` |
| `cache_spec.lua` | the per-buffer changedtick-keyed scan cache: hit, `changedtick`-invalidation on edit, explicit `invalidate`, and a deleted buffer never being a hit |
| `regions_spec.lua` | turning a scope into concrete byte/line ranges to scan |
| `native_spec.lua` | the native `:spellgood`/`z=`-backed provider |
| `collect_spec.lua` | gathering issues across providers/scopes and de-duplicating them |
| `spell_ui_spec.lua` | `ui/highlights.lua` and `ui/list.lua` — diagnostic namespace, the per-buffer `max` cap |
| `spell_ui_kit_spec.lua` | `ui/item_menu.lua` and `ui/panel.lua` against the real `ui.kit` (ui.nvim is a suite dependency): which actions a spelling vs a grammar issue offers, each action's call into the core and `on_done`, the suggestion picker (and an empty choice), the panel rows/title, the buffer-local direct keys (`a`, `i`, `I`, `L`, `gd`, `o`, `?`), `on_cancel` clearing the diagnostics; only the window-opening kit calls and the mutating core actions are replaced by recorders |
| `live_spec.lua` | debounced live re-scanning on buffer change |
| `wordlists_spec.lua` | the built-in programming dictionary and extra-wordlist merging; `session_words`: a batch costs two `:spellgood!` commands instead of one per word, known words are not re-added (the counter drains the scheduled flush first, so these zero-command checks can really fail), invalid entries are dropped (also blank-only, U+FEFF and trailing-slash entries at either end of a batch, which would break the first/last-word handshake), the per-word fallback (list file not found, or a wrong file found) still lands every word, and with no temp dir at all the lookup returns nil and never touches the working directory |
| `job_spec.lua` | `util/job`: argv/opts plumbing, `on_done`, a spawn failure reported through `on_done`, `cancel()` before completion suppressing it, and the Windows `cmd.exe /c` guard (a `.cmd`/`.bat` launcher is refused when an argument holds a quote, `%`, `^`, `&`, `\|`, `<`, `>` or a line break; the platform is injected, so it runs everywhere) |
| `spell_providers_cli_spec.lua` | the CLI/LSP spell providers (`codespell`, `cspell`, `custom`, `lsp`, `typos`) and their shared `util.lua`, all with the underlying process/LSP client stubbed |
| `spell_providers_cspell_server_spec.lua` | the persistent Node/cspell-lib sidecar (`cspell_server.lua`): `available()`, `resolve()`'s nested/hoisted candidate paths and its failure case, `ensure_started()`'s reentrancy and `jobstart` failure, `on_stdout`'s line buffering (including a line split across two chunks), the ready/error/id-reply dispatch, request/reply round-tripping with issue tagging, `cancel()`, `on_exit()` dropping pending requests, and the `VimLeavePre` kill handler — with `language.util.job` and `vim.fn.jobstart`/`chansend`/`jobstop` stubbed, never a real node or cspell-lib |
| `translate_filter_indent_spec.lua` | the line filter that skips fenced code/front-matter and every line holding a backtick (prose around a code span, a stray lone backtick), and re-indenting translated output to match the source |
| `translate_output_spec.lua` | applying translated output back to a buffer, register, or via notify |
| `translate_history_spec.lua` | recording/labelling/picking/clearing translation history, including label clipping for long input |
| `translate_chunk_spec.lua` | `translate/chunk.lua`, the wrapper around every engine: block boundaries (blank lines preferred, `max_lines`), `limits_for` (`max_chars` lowers, an engine's own option may raise), blank block edges surviving an engine that trims them (gtx / `trans` / a parse that splits the output on newlines and so gains a trailing empty line), a blank-only block never being sent, an over-long line cut at sentence/word boundaries (ASCII and CJK, never inside a UTF-8 character) and re-joined into one line, pinned rule by rule with exact pieces (each sentence and clause mark, the half-budget rule, boundaries that fall exactly on the budget, trailing white space trimmed from a piece, blank over-long lines left alone), packing of the pieces into requests (the byte budget, `max_lines` — more than 50 pieces of one line never share a DeepL request), a single token over the budget still failing with a message that says why, `translate.max_blocks`, the wrapper's contracts (empty input, surplus lines in an answer, a double callback, `cancel()` in every state, unusable config values), and the registry's google path with a stubbed job (a 3 600 character line, a 600 character Japanese line and a 40 000 byte line all translate) |
| `translate_providers_spec.lua` | the translate engines — registry resolution/fallback, and each provider's (`google`, `deepl`, `shell`, `custom`) request-building and response-parsing (google: the text is the stdin of a POST, not part of argv/URL; deepl: the stdin config is quoted by `lib.nvim.net.curl.config_quote`; shell/custom: the platform-dependent budget and `translate.custom.max_bytes`), with `util/job` stubbed so nothing hits curl or a real network |
| `translate_markdown_segment_spec.lua` | `translate/markdown/segment.lua`: what is never translated (front matter, fences, HTML blocks, definitions, indented code, math, table delimiter rows) and what is a unit (headings, paragraphs, items, quotes, every table cell), prefixes kept apart from content, hard breaks ending a unit, the container rules (a fence, a table or a list ends with its quote / item / first-column block; four columns beyond the container are code, so no fence or table opens and no closing fence closes there; text of an outer item; a `>` inside a fence; tab-indented fences; linear time on one long line, also a `<` with a long name and no `>`, a tag on a line of its own is an HTML block; setext, first-cell, math, front-matter, tab, CRLF and `[label]:` edge cases) and the round trip (rendering unchanged reproduces the source byte for byte, also over a fuzz of random fragment mixtures) |
| `translate_markdown_mask_spec.lua` | `translate/markdown/mask.lua`: what is masked (inline code, both halves of a link, autolinks, bare URLs, entities, footnote refs, keep words), that a placeholder is ASCII `{n}`, restoration byte for byte, the `check` gate (a lost, repeated or unknown placeholder, a link whose halves swapped) the bounded look-ahead (unclosed brackets, destinations and backtick runs stay linear; a unit that used up the budget is `degraded`), many addresses or unclosed comment openers in one unit without a quadratic scan, and the end of an address (a run of punctuation behind it, many `https://` in one run or in a link text), a tag with a long name and many `[^` without a quadratic match, an address at the end of a link text masked, the sentence punctuation trimmed as before; `_` in the domain label of a bare e-mail address; `normalize` and `unmask` as `find` loops giving the answers of the `gsub` they replaced (every placeholder at every edge, what is no placeholder staying, placeholders next to each other), `has_text` without a copy, the e-mail and `www.` addresses merged in order (interleaved, an address inside an address masked once, whole) |
| `translate_markdown_reflow_spec.lua` | `translate/markdown/reflow.lua`: exactly n lines, widths steering the split, the golden "no break before a block-start token" test (the dash that became a list item), fewer words than lines, a 3 000-case property test, the delimiter-row guard and a comparison with the plain full-range break search |
| `translate_markdown_anchors_spec.lua` | `translate/markdown/anchors.lua`: the slug of the mdview client (Unicode letters/numbers/white space, combining marks, final sigma, invalid bytes), the heading text as the previewer reads it, the old-to-new map with `-1` numbering and the rewriting of link and definition targets |
| `translate_markdown_cache_spec.lua` | `translate/markdown/cache.lua`: the key, the bounded memory cache, the disk file (persistence, size cap, merge with another instance, damaged and malformed files) in a fixture directory |
| `translate_markdown_slice_spec.lua` | the cooperative slicing of `translate_markdown`: the slicer on its own (a yield at every tick with a budget of 0, `stop()` abandoning the work, errors of a later slice reported, a generous budget never yielding), the interruption points of `segment`, `render` and `anchors.build_map`, the result of a run that yields at every point equal to the unsliced one (fixtures, a warm cache, a 120-case fuzz with a sync and an async engine, `info`, the blocks reported), the longest block of the event loop on 20 000 lines (a 1 ms timer: mixed document with an engine that answers inside `translate` and in a later turn, a warm cache, `cache_only`; 10 000 headings; one text 20 000 times, also with a progress callback) staying under 50 ms, a document under 2 000 lines, 64 kB and the cost estimate not sliced and calling back in the first turn, a table of 8 800 cells under the old limits sliced (longest block of the loop under 50 ms), a cancel and a stale token between two slices ending the work without asking the engine, ONE line of a megabyte (sync and async engine, `cache_only`) staying under the stall limit with the result of the unsliced run and `done` counting up, an engine answering inside `translate` never having a yield cross its call (the inline booking under `sl.hold`; a reflow of more than 256 words, `coroutine.yield` counted) |
| `translate_markdown_slice_sites_spec.lua` | the interruption points of `translate_markdown`, pinned one by one and cheap: an unlimited slicer budget never reading the clock (`uv.hrtime` counted), what counts as a small document (lines AND bytes, the 64 kB boundary, an explicit `slice_ms` winning), every `tick()` of the pipeline counted between markers of the pipeline (segment, the loops over blocks and headings, mask, cache pass, partition, batching, pump, anchor map, content loop, render, reference definitions) so a removed call shows as a smaller number on any machine, the cache pass ticking between the units of one entry, the answer for 600 identical units booked over many turns of the loop and the call not ending before the last report, one answer of 40 entries of 30 units each bounded as a whole (most reports in one turn), a throw while an answer is booked (sync and async engine, whole and sliced) ending the call once with the error contract, the cost estimate of what a small document is (cells, list items, long paragraphs), the blocks that waited for the anchor map reported in slices, and what the order of `on_unit` guarantees (one event per block, `done` counting up, the waiting blocks before the heading that completed the map), `slice.every` (every n-th call a real tick, `nil` a no-op) and `slice.hold` (held ticks no-ops, a run started inside yields, a hold that threw released and the rest resumed), the counting ticks inside ONE unit counted per function (mask scan and look-aheads, check, normalize, unmask, `adds_syntax`, reflow words and break search) and handed on by `translate_markdown`, and a block that gives way while it is rendered for `on_unit` not overtaken by one booked in that gap |
| `translate_markdown_spec.lua` | `translate_markdown` against a fake engine: golden documents (`TESTS/fixtures/markdown/`) with the same line count, byte-identical fences, restored placeholders and unchanged block types, the dash rule for every block-start token, anchors, validation/retry/fallback and "a failure is never cached", batching and concurrency, progress events, `cache_only`, cancellation, stale tokens, `cb` exactly once, a 250-case fuzz of the whole pipeline, the review-round regressions (setext heading, first cell, cell pipes, anchors of unchanged units, linear time on a 6 000-line paragraph, CRLF) and the independent-review ones (an answer that adds a link, image, tag, `www.` or e-mail address is refused, a degraded unit is not sent, an answer with a long run of white space is validated in linear time) and the second review round (an e-mail address in the forms the previewer links but a plain `%w@` test misses, `_@x.example`, `+@x.example`, `.@x.example`, `a@x_y.example`, is refused; the visible address of a link cannot be swapped for another one; a unit of 12 500 `https://`, a run of `)` behind an address and a `<` with a long name are masked, wrapped and checked in linear time; the hard-break address check looks at the last word only); the address guard compares the addresses (a swapped or repeated unmasked address is refused, a kept one is accepted with other punctuation or CJK text behind it) |
| `translate_ai_provider_spec.lua` | the `ai` engine (`translate/providers/ai.lua`) against a fake `ai` module: request shape and bulk profile, strict parse (fence, count, types, placeholders, line breaks), one retry, policy and bulk-limit errors, cancel, chunking by the bulk budget, registry behaviour (no silent fallback), the cache identity as ai.nvim resolves it, no `bulk.reset` of an old run (it would refund the session cap), an ai.nvim without `ai.bulk` |
| `translate_markdown_curl_spec.lua` | the placeholder over the REAL curl path: the full pipeline (registry, chunk wrapper, `custom` engine, `util/job`, a curl process) against a loopback HTTP server in the spec's own editor; skipped without curl |
| `translate_custom_stdin_curl_spec.lua` | non-ASCII text (umlaut, CJK, `⟦⟧`) over the `custom` engine's `stdin` field and a REAL curl arrives at a loopback server as UTF-8, and an argv element leaves the editor as exact UTF-8 (checked with an nvim child); skipped without curl |
| `translate_init_spec.lua` | `translate.run`'s scope handling and buffer replace |
| `translate_window_keys_spec.lua` | the interactive window's keys against the real `ui.kit`: the target picker of `open()`, `<C-l>` retarget (title, refresh, empty target ignored), `<C-r>` reverse (nothing while the output is empty, output becomes input, next target asked), `<C-y>` copy and history record, `<C-h>` history entry, `q` close; picker, refresh and history file are recorders |
| `translate_motion_spec.lua` | the operator/motion entry point into translate |
| `translate_files_spec.lua` | `translate.files.process`/`run` against a fake provider — suffix/replace/buffers output modes, error handling, and the early-return guards, all without reaching `ui.kit`'s file picker |
| `thesaurus_spec.lua` | looking up and applying a synonym under the cursor, off the `ui.kit` picker branch |
| `bindings_usrcmds_spec.lua` | `:Spellcheck`/`:Translate`/`:TranslateReplace` argument parsing and dispatch (`path=<dir>` and `path=<file>` go to `run_files` without `--nocode`, a missing path is an error), with `language.spell`/`language.translate`/`language.translate.window` stubbed |
| `usrcmds_help_spec.lua` | every flag and positional argument of `:Translate`/`:TranslateReplace`/`:Spellcheck` has a line in lib.nvim's option float: `composer.help.undocumented(<verb>, { args = true })` is empty, the four argument-type texts and every flag / enum-value text keep the house style (one line, at most 80 characters, no trailing period), and the texts say what the code does (`--nocode` skips whole lines with inline code and is ignored for `cword`/`cwd`/`path=<p>`; `path=<p>` is a file or directory) |
| `bindings_keymaps_autocmds_spec.lua` | keymap registration for spell/translate/thesaurus, and the autocmd wiring (including the live-scan debounce arm/disarm and the write guard) |
| `language_init_spec.lua` | `language.setup()` end to end — command registration gating, idempotency, the lazy `M.health` facade, and the programming_dict/extra_wordlists gate |
| `spell_init_spec.lua` | the top-level `language.spell` facade — starting/closing a session, `:Spellcheck`'s scope dispatch, panel stubbed (`spell_ui_kit_spec.lua` covers the panel itself) |
| `config_spec.lua` | the merge, and that `DEFAULTS` survives it unmutated |
| `hover_spec.lua` | the word under the cursor as a hover.nvim float — the word finder, the target language, decline-vs-fail, the rate-limit failure path, and `on_request` registration (translate provider and hover.nvim both stubbed) |
| `health_spec.lua` | `:checkhealth language` (`M.check()`) branch by branch: version/native-provider detection, every optional-tool present/absent pair (including the cspell-without-node middle case), the attached-grammar-client list, deepl-key resolution, the effective-config echo, and `check_hover()`'s four states — with every collaborator (tools, LSP clients, hover.nvim, which-key, `lib.nvim.deps.health`) stubbed or monkeypatched; also the old-lib.nvim case (no composer module: one warning, the tail skipped, no crash) and the ui.nvim line (warn without, ok with) |

Adding one: write `TESTS/<name>_spec.lua` returning `function(H) ... end`, then
run `scripts/test.sh` (it is discovered by its `_spec.lua` suffix). `H` is the harness — `eq`, `ok`, `falsy`, `contains`,
`excludes`, `read`, `fixture`, `track` and `tracked`.

Every spec file runs in an editor of its own (`isolated = "file"`), whose cases
share it, and testing.nvim's state guard runs at `error`
(`.testing.lua`): a spec that leaves a buffer, window, `:Command`, keymap,
autocmd or changed option behind fails the run. A spec that calls `setup()` or
creates any of these wraps its body in `H.tracked(function() ... end)` (pass
`H.tracked({ options = { ... } }, function() ... end)` for global options it
changes). It puts everything back when the body ends, also when an assertion
fails half-way, so one red case does not leave a dirty editor to the next one:
new buffers and windows are wiped, new autocmds deleted, and global keymaps and
user commands return to their recorded state (added ones deleted, replaced or
removed ones set again). `H.track()` is the same without the body: it returns
the restore function.

## Coverage

Every `lua/language/**/*.lua` file with real logic or branching that can be
required (the spell panel and item menu with the real `ui.kit`) now has a dedicated real-assertion spec: both spell
cores (split/scope/regions/collect/cache/ignore/actions), the native,
CLI/LSP, and persistent-sidecar spell providers, live scanning, the
wordlists, `util/job`, every translate provider plus the registry's fallback
chain, translate's filter/indent/output/history/files/motion pieces, the
thesaurus, all three bindings modules, `language/init.lua`'s `setup()`, and
`health.lua`'s `M.check()` branch by branch (not just the lazy facade that
resolves it). `ignore.add_persistent`, previously excluded for writing into
the developer's real `stdpath("state")` ignore file, is covered too —
redirected to a fixture path via the existing `spell.dictionary.ignore_file`
config option, which needed no source change. `cspell_server.lua`, previously
excluded outright as needing a real Node/cspell install, is covered the same
way the other CLI providers are: every real external call it makes goes
through `language.util.job` or a plain `vim.fn.*` global, both stubbable, so
its own logic (candidate resolution, line buffering, request/reply matching)
is exercised without ever spawning node or cspell-lib for real.

### Known bugs pinned by these specs (not fixed here)

Some specs assert the *current*, buggy behavior on purpose rather than
silently patching it — grep any spec file for `BUG:` for the full reasoning
inline. As of this audit:

- **`spell_init_spec.lua`** — `spell.clear()` does not actually restore a
  buffer's previous `'spelllang'` when the quickfix view (not the panel) is
  in use; it restores the wrong window's option.

### Deliberately left untested

- **`config/DEFAULTS.lua`** — a plain data table (`return { ... }`); its merge
  behavior is what `config_spec.lua` actually tests.
- **`@types` modules** (`language/@types`, `config/@types`,
  `spell/@types`, `translate/@types`) — `---@meta`-style annotation files, no
  runtime behavior.

Translation itself (`curl`/network), the shell-based spell providers, and the
persistent cspell sidecar's actual process stay stubbed at the `util/job` /
`vim.fn.*` boundary throughout — none of this suite spawns a real process,
a real Node runtime, or touches the network.
