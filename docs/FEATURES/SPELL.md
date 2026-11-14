# Spell

Spelling and grammar checking, with a session model that lets you fix
issues without leaving the buffer.

## Spell/grammar session

`:Spellcheck` starts (or toggles off) a per-buffer review session built on
native `vim.spell`, publishing issues as diagnostics with a Trouble panel
(if installed) or quickfix fallback. `]s` jumps to the next issue,
`<leader>z=` opens a fix/suggestion picker on the issue under the cursor,
`<leader>z1` applies the first suggestion directly — both advance to the
next issue afterward. Ending the session (`:Spellcheck clear`) restores the
buffer's original `spelllang` and clears diagnostics.

The review panel opened by `:Spellcheck`/`<leader>ss` is a chooser list, one
row per issue. `<CR>` opens the full action menu on the issue under cursor
(suggestions, replace-all, add to dictionary, ignore, jump, or an LSP fix for
grammar/style issues) — the same menu also reachable directly by key, without
the extra round-trip: `a` add to dictionary, `i`/`I` ignore (session/
persistent), `L` apply an LSP fix, `gd`/`o` jump to the word under cursor
(closes the panel). `?` opens a cheatsheet of every key available in the
panel. A key not applicable to the issue under cursor (e.g. `a` on a grammar
issue) is reported rather than silently ignored.

- **Tab:** true
- **Module:** `spell/init.lua`, `spell/ui/{panel,item_menu,list}.lua`, `spell/core/{collect,actions}.lua`
- **Keymaps:** `<leader>ss` (toggle), `]s` (next), `<leader>z=` (fix), `<leader>z1` (fix1) — see [keymaps](../BINDINGS.md#keymaps)
- **Panel keys:** `<CR>` menu, `a` add to dictionary, `i`/`I` ignore (session/persistent), `L` LSP fix, `gd`/`o` jump, `?` help
- **Usercmds:** `:Spellcheck [lang] [buffer|visible|cwd|path=<p>|clear|refresh]` — [user commands](../BINDINGS.md#user-commands)
- **Config:** `opts.spell.default_scope` (default `"buffer"`), `opts.spell.ui.view` (`"picker"`/`"quickfix"`)

### From a node of a tree view

`setup()` registers the action `language.check` at `lib.nvim.tree.registry`:
"Spell check this file or folder". A tree that reads the registry (the own
tree of [filetree.nvim](https://github.com/WKDSteve/filetree.nvim), `adapter =
"native"`) offers it on every node that is a file or a folder on disk, in its
context menu and its action list. It does what `:Spellcheck path=<node>` does
and opens the same review; the path is taken as it is, so a name with a blank
or a `$` needs no quoting. With several nodes marked it checks the first and
says so.

```lua
require("language").setup({
  tree = { key = { check = "<leader>sc" } }, -- also on a key in the tree buffer
  -- tree = false,                           -- not offered (this and "Translate this")
})
```

Without a tree that reads the registry the entry is never looked at.
`require("language.integrations.tree").check(path)` runs the same check for
any path.

- **Module:** `integrations/tree.lua`
- **Config:** `opts.tree` (default `true`)

### Per-buffer scan cache

Native scans are cached keyed by `changedtick`, so re-opening the panel or
re-triggering a live scan on an unchanged buffer doesn't re-run `vim.spell`
from scratch.

- **Module:** `spell/core/cache.lua`

## Grammar via LSP

Grammar/style diagnostics from `harper_ls` or `ltex` are harvested and
merged into the same session/panel as spelling issues. In the panel,
grammar issues offer an "Apply LSP fix…" action that runs the language
server's code action at the issue location instead of a suggestion list
(which is reserved for spelling issues).

- **Module:** `spell/providers/lsp.lua`

## External spell/grammar providers

For `cwd`/`path` scope, an external CLI provider is preferred over the
native walker when configured: `typos`, `cspell`, or `codespell`, each
dispatched async through a shared collection layer (a single process across
the whole tree rather than per-file).

- **Module:** `spell/providers/{typos,cspell,codespell,util}.lua`, `spell/core/collect.lua`
- **Config:** `opts.spell.providers.cwd` (list of provider names)

## cspell sidecar (persistent Node process)

An opt-in, always-warm cspell-lib process (`node/cspell_server.js`) started
once and talked to over stdin/stdout — checks are near-instant with no
per-scan cold start, and it's code-aware (understands identifiers/comments
like the CLI does) and usable for live/buffer scanning, not just cwd/path.
Requires `node` and `cspell` on the machine.

- **Module:** `spell/providers/cspell_server.lua`, `node/cspell_server.js`
- **Config:** `"cspell_server"` in `opts.spell.providers.buffer`

## Native recursive directory scan

When no external CLI provider is available for `cwd`/`path`, a real native
fallback walks the directory tree on disk (not just already-open buffers):
async, 20 files per tick via `vim.schedule`, cancellable, with
`lib.nvim.progress` feedback. It prefers live buffer content for open files
and reads closed files fresh from disk, skipping vendor directories
(`.git`, `node_modules`, `.venv`, `dist`, `build`, `target`, `.cache`,
`__pycache__`), files over 5MB, and files over `spell.max_file_lines`.

- **Module:** `spell/providers/native.lua` (`scan_tree`), `spell/core/collect.lua` (`native_tree`)

## Code-aware detection

Native detection splits `CamelCase`/`snake_case` identifiers into
sub-words before checking each one, and restricts checking to
Treesitter `@spell` regions (comments, strings, prose) so identifiers
outside those regions never produce false positives. URLs and email
addresses are skipped. An opt-in programming dictionary
(git/kubernetes/treesitter/etc. terms) reduces further noise, and
`extra_wordlists` does the same for your own vocabulary.

Both go into Neovim's session word list, like `zG`: they count for every
`'spelllang'`, are gone when Neovim exits and never touch your `'spellfile'`.
The lists are compiled once rather than word by word, so a few hundred words
cost a few milliseconds at startup.

- **Module:** `spell/core/split.lua`, `spell/core/regions.lua`, `spell/programming_dict.lua`, `spell/extra_dict.lua`, `spell/session_words.lua`
- **Config:** `opts.spell.word_split.enable` (default `true`), `opts.spell.regions.treesitter_spell` (default `true`), `opts.spell.programming_dict` (default `false`), `opts.spell.extra_wordlists` (default `{}`)

## Live scan

Opt-in, debounced background scanning decoupled from the session/panel —
scans configured filetypes on `BufWinEnter`/`FileType`, then rescans on
`TextChanged`/`InsertLeave`. By default only the visible range is scanned
(`live_scope = "visible"`), following the viewport as it scrolls
(`WinScrolled`); honors the same filetype/`max_file_lines`/readonly/
`max_highlights` gates as the session scan.

- **Module:** `spell/live.lua`
- **Config:** `opts.spell.live` (default `false`), `opts.spell.live_scope` (`"visible"`/`"buffer"`), `opts.spell.scan_debounce_ms` (default `400`)

## Buffer highlights

Independent of `vim.diagnostic`, marks issues directly in the buffer via
extmark (`underline`/`undercurl`) using dedicated, colorscheme-overridable
highlight groups (`LanguageSpellHighlight`/`LanguageGrammarHighlight`).
Wired through the same publish/clear choke point every scan path
(session, live scan, panel) already uses, so enabling it applies
everywhere automatically.

- **Module:** `spell/ui/highlights.lua`
- **Config:** `opts.spell.highlights.enable` (default `false`), `opts.spell.highlights.style` (`"underline"`/`"undercurl"`)

## Silencing false positives

Inline directives in a comment — `language:disable-line`, `-next-line`,
`-file` — suppress issues without touching global config, alongside a
persistent ignore list and a per-buffer dictionary
(`dictionary.replace_all` applies a suggestion to every occurrence at
once). Opt-in `spell.guard.block_write_on_error` aborts `:w` while
spelling errors remain on a matching filetype (bypass with
`:noautocmd w`).

- **Module:** `spell/core/ignore.lua`, `spell/core/actions.lua`
- **Config:** `opts.spell.guard.block_write_on_error` (default `false`)
- **Autocmds:** `BufWritePre` guard — [autocmds](../BINDINGS.md#autocmds)

## Custom spell CLI

An escape hatch for a checker without a built-in adapter: `{ cmd =
function(scope, cfg) ... end, parse = function(out, base) ... end }`,
registered next to the built-in CLI modules and activated by adding
`"custom"` to `spell.providers.cwd`. Mirrors `translate.custom`'s shape.

- **Module:** `spell/providers/custom.lua`
- **Config:** `opts.spell.providers.custom`, `"custom"` in `opts.spell.providers.cwd`
