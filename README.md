![language-nvim](assets/icons/language-nvim/png/language-nvim-128.png)

> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# language.nvim

```
 _               _   _  _____ _    _         _____ ______
| |        /\   | \ | |/ ____| |  | |  /\   / ____|  ____|
| |       /  \  |  \| | |  __| |  | | /  \ | |  __| |__
| |      / /\ \ | . ` | | |_ | |  | |/ /\ \| | |_ |  __|
| |____ / ____ \| |\  | |__| | |__| / ____ \ |__| | |____
|______/_/    \_\_| \_|\_____|\____/_/    \_\_____|______|
                                                     .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
[![CI](https://github.com/WKDSteve/language.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/WKDSteve/language.nvim/actions/workflows/ci.yml)
[![wkd](https://img.shields.io/badge/wkd-family-c6ff3d)](https://wkdsteve.github.io/wkd/p/language/)

> Part of the [wkd](https://wkdsteve.github.io/wkd/) family — see this plugin's [page](https://wkdsteve.github.io/wkd/p/language/) on the site.

Spelling, grammar, translation and synonyms in one plugin, all of it
asynchronous and all of it acting on the buffer you are already in.
Translation needs no external Neovim plugin — `curl` and the keyless Google
endpoint work with zero configuration. Subtitle files (`.srt`, `.vtt`) are
recognised on their own: only the cue text is translated, while indices,
timing lines, headers and tags stay byte-identical.

---

## Around it

> **[hover.nvim](https://github.com/WKDSteve/hover.nvim)** — the word under
> the cursor, translated into a float. It is asked only on request rather than
> on every hover, because the keyless endpoint answers a passive contribution
> with HTTP 429 — the measurement is in
> [docs/FEATURES/HOVER.md](docs/FEATURES/HOVER.md).
>
> **[sessions.nvim](https://github.com/WKDSteve/sessions.nvim)** — restores
> your workspace by project and branch, so a spell session and its target
> language come back where you left them instead of being set up again.
>
> **[trouble.nvim](https://github.com/folke/trouble.nvim)** — a nicer list for
> the diagnostics a spell session produces. The session works without it; the
> quickfix list is the fallback.
>
> All of the above are soft: without them everything else works unchanged.
> [lib.nvim](https://github.com/WKDSteve/lib.nvim) is the one real
> dependency — see [Requirements](docs/requirements.md).

---

## Documentation

Start at [docs/README.md](docs/README.md), which says what is where and which
question each page answers.

### The Basics

- [Requirements](docs/requirements.md) — Neovim version, required plugins and CLI tools.
- [Installation](docs/installation.md) — every plugin manager, and how to check that it took.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

### Configuration

- [What you get with the defaults](docs/what-you-get.md) — the full command/key surface at a glance.
- [All options](docs/configuration.md) — every `setup()` option over the defaults in `lua/language/config/DEFAULTS.lua`.
- [Usage](docs/usage.md) — the command reference: scopes, flags, and how to end each thing again.
- [Bindings](docs/BINDINGS.md) — every keymap, user command and autocmd, all of them opt-in and carrying a `desc`.

### The Rest

- [Features](docs/FEATURES/README.md) — one page per theme: spell, translate, thesaurus, the shared core, and the hover contribution.
- [Workflow](docs/WORKFLOW.md) — how the pieces combine into a habit, and the two traps: `:Translate` against `:TranslateReplace`, and reading the confirmation before `--files=replace`.
- [Health check](docs/health.md) — the nine `:checkhealth language` sections, and which findings are actually problems.
- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add a provider.
- [Feedback](https://github.com/WKDSteve/language.nvim/issues) — bugs, feature requests and usage questions; broader discussion in [Discussions](https://github.com/WKDSteve/language.nvim/discussions).

`:help language` is the same reference inside the editor.

---

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

language.nvim is released under the [MIT License](https://opensource.org/licenses/MIT).
