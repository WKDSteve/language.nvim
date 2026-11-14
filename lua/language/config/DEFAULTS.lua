---@module 'language.config.DEFAULTS'
---@brief Plugin-side default configuration for language.nvim.
---@description
--- Overridden by user options passed to require("language").setup().
--- See config/@types for the full LanguageConfig type. The tree is split into
--- two independent domains: `spell` (spelling + grammar) and `translate`.

require("language.config.@types")

---@type LanguageConfig
local defaults = {
  -- Master switch of every keymap the plugin binds (global and session-local).
  -- `keymaps = false` is accepted by setup() and means `{ enable = false }`.
  keymaps = { enable = true },
  spell = {
    providers = {
      order = { "native", "lsp", "typos", "cspell", "codespell" },
      buffer = { "native", "lsp" },
      cwd = { "typos", "native" }, -- CLI preferred for tree scan
      native = { spelllang = nil }, -- nil = inherit vim 'spelllang'
      lsp = { enable = true, servers = { "harper_ls", "ltex" } },
      -- Escape hatch for a spellchecker CLI without a bundled adapter: add
      -- "custom" to `providers.cwd` and set cmd/parse. Mirrors translate.custom.
      custom = nil, -- { cmd = function(scope, cfg) ... end, parse = function(out, base) ... end }
    },
    filetypes = { "markdown", "text", "gitcommit", "tex", "rst", "asciidoc", "help" },
    default_scope = "buffer", -- buffer|visible|cwd|path
    live = false, -- opt-in live scan
    live_scope = "visible", -- perf: live only within the visible range
    scan_debounce_ms = 400,
    -- Code-identifier splitting: break CamelCase & snake_case into subwords
    -- before checking against the dictionary.
    word_split = { enable = true, min_length = 4 },
    -- Perf/safety caps:
    max_highlights = 100, -- max highlighted errors per buffer
    max_file_lines = 20000, -- above this: no auto/live scan
    skip_readonly = true, -- do not scan readonly buffers
    -- Only check spellable regions (Treesitter @spell / predicate):
    regions = { treesitter_spell = true, skip_urls = true, skip_emails = true },
    programming_dict = false, -- opt-in: technical wordlist, added to the session word list
    -- User-supplied session wordlists, applied the same way as
    -- programming_dict (session word list, like `zG`) but independent of it and
    -- of `spelllang` — e.g. domain vocabulary that keeps getting flagged when
    -- writing non-English technical prose. { ["my-list"] = { "word1", ... } }
    extra_wordlists = {},
    ui = {
      view = "picker",
      preview = true,
      group_by = "file",
      dedupe = true,
      -- How long to wait after an LSP code action before re-reading the
      -- buffer. There is no completion signal to hook, so this is a guess at
      -- the server's latency -- raise it for a slow one.
      lsp_refresh_delay_ms = 500,
    },
    dictionary = {
      ignore_file = vim.fn.stdpath("state") .. "/language/spell_ignore.txt",
      use_spellfile = true,
      replace_all = true, -- apply suggestion to all identical errors in scope
    },
    guard = { block_write_on_error = false }, -- opt-in: abort :w on spelling errors
    -- Opt-in: mark issues directly in the buffer via extmarks (LanguageSpellHighlight/
    -- LanguageGrammarHighlight highlight groups), independent of vim.diagnostic config.
    highlights = { enable = false, style = "underline" }, -- style: "underline"|"undercurl"
    keymaps = {
      panel = "<leader>ss",
      next = "]s",
      fix = "<leader>z=",
      fix1 = "<leader>z1",
    },
  },

  -- Register a position preview with hover.nvim, so `:Hover show` over a word
  -- answers with its translation. `on_request` there, so the automatic hover
  -- trigger never asks -- every answer is a network request carrying the word
  -- under the cursor, and that belongs to a deliberate press rather than to a
  -- quiet moment. A no-op without hover.nvim installed; see lua/language/hover.lua.
  hover = true,

  translate = {
    engine = "google", -- "google"|"deepl"|"shell"|"ai"|<custom>
    fallback = { "google" }, -- engines tried after `engine` when it is unavailable or its request fails (only these)
    default_output = "popup", -- "popup"|"replace"|"buffer"|"vsplit"|"split"|"tab"|"insert"|"clipboard"|"notify"
    default_input = "selection", -- selection|clipboard|input
    default_langs = { "EN", "DE", "FR", "ZH", "JA" },
    default_target = nil, -- fixed target for motion/visual maps; nil = prompt
    nocode_default = false,
    timeout_ms = 8000, -- network timeout per request; a large input is split into several, each gets this budget
    max_chars = 0, -- lower the per-request block budget in bytes (DeepL: bytes + 8 per line; 0 = provider default); larger inputs are split on line boundaries
    max_blocks = 50, -- most requests one call may need; an input that needs more is refused before the first request (0 = no limit)
    block_pause_ms = nil, -- pause between the requests of one call; nil = engine default (google/shell 300: the keyless endpoint rate-limits, others 0)
    deadline_ms = 0, -- budget for the whole call, across all its requests (0 = none; timeout_ms still applies per request)
    deepl = { api_key = nil }, -- or ENV "DEEPL_API_KEY"
    -- engine = "ai": translation through ai.nvim (soft dependency, bulk profile, policy-checked).
    ai = {
      provider = nil, -- ai.nvim provider id ("claude", "ollama", ...); nil = ai.nvim's own choice
      model = nil, -- model; nil = the one ai.nvim is configured with
      glossary = nil, -- { Term = "Begriff" } fixed translations, or { "Neovim" } terms kept as they are
      style = nil, -- tone, e.g. "formal, second person"
      max_chars = 6000, -- largest request (prompt + system), in characters
      concurrency = 2, -- requests in flight per run
      max_total_chars = 500000, -- cumulative characters per run (a document); false = no cap
    },
    -- cmd returns the argv; a `stdin` field of it goes to the process (use it for non-ASCII text on Windows)
    custom = nil, -- { cmd = function(text, target) ... end, parse = function(out) ... end, max_bytes = nil }
    -- translate_markdown(): the Markdown-safe document translation (docs/FEATURES/TRANSLATE.md).
    markdown = {
      concurrency = 3, -- requests in flight at once
      max_chars = 3000, -- masked bytes per request (units are batched up to this)
      disk_cache = true, -- keep translated units in stdpath("cache")/language.nvim across sessions
      cache_max_kb = 2048, -- size cap of that file; the oldest entries go first
      keep = {}, -- words that are never translated (proper names), e.g. { "Neovim" }
    },
    -- Recall previous translations (:Translate history picker / window <C-h>).
    history = {
      enable = true,
      max = 50, -- ring size
      persist = false, -- also save to disk (JSON) across sessions
      file = vim.fn.stdpath("state") .. "/language/translate_history.json",
    },
    -- Opt-in motion/visual keymaps (off by default to avoid clobbering keys):
    --   operator: `<lhs>{motion}` translates the moved-over text (e.g. gtrip)
    --   visual:   `<lhs>` translates the visual selection
    --   to:       one key per language, forcing that target for a single run
    --             (e.g. to = { EN = "<lhs>", DE = "<lhs>" }). Works in both
    --             normal (operator) and visual mode. Unset by default.
    --             A count cannot carry the language on an operator -- there it
    --             belongs to the motion -- hence a key per language.
    keymaps = { operator = false, visual = false, to = {} },
    -- Multi-file translation (:Translate cwd / path=<p>): pick files (kit
    -- multi-select, <Tab>), then per file:
    --   "suffix"  → write a sibling file  name.<TARGET>.ext  (non-destructive, default)
    --   "replace" → overwrite the file in place (asks for confirmation first)
    --   "buffers" → open each translation in a scratch buffer (no disk write)
    -- Override per call with `--files=<mode>`.
    files = {
      output = "suffix",
      extensions = {
        "md",
        "markdown",
        "txt",
        "text",
        "rst",
        "adoc",
        "asciidoc",
        "tex",
        "org",
        "srt",
        "vtt",
      },
      max_kb = 512,
    },
  },

  -- Thesaurus / synonyms (writing aid). Default source is the free, keyless
  -- Datamuse API (English). Set a `custom` function for another source/language.
  thesaurus = {
    enable = true,
    source = "datamuse", -- "datamuse" | "custom"
    max = 20,
    timeout_ms = 6000,
    keymap = false, -- opt-in: replace the word under the cursor with a synonym
    -- custom = function(word, cb) cb({ "syn1", "syn2" }) end,
  },

  commands = true,

  -- "Spell check this" and "Translate this" on a node of a tree view (the own
  -- tree of filetree.nvim reads them from lib.nvim's registry). true: in the
  -- tree's menu and action list; { key = { check = "<lhs>", translate = "<lhs>" } }:
  -- on those keys in the tree buffer as well; false: not offered.
  tree = true,

  which_key = { enable = true },

  -- One-time "which CLI tools does this plugin want, and why" popup on
  -- first setup() after install (via lib.nvim.deps). false disables it for
  -- this plugin specifically, right here in the spec passed to setup() —
  -- no vim.g needed. See README "Health".
  deps_popup = true,
}

return defaults
