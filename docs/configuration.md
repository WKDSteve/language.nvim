# Configuration

`setup()` merges over the defaults (see `lua/language/config/DEFAULTS.lua`).
Excerpt:

```lua
require("language").setup({
  -- Register an on-request position preview with hover.nvim: `:Hover show`
  -- over a word answers with its translation. Never on hover's automatic
  -- trigger -- every answer is a network request carrying that word. A no-op
  -- without hover.nvim installed. See docs/FEATURES/HOVER.md.
  hover = true,
  spell = {
    default_scope = "buffer",
    live = false,                -- true = continuous inline diagnostics while typing
    live_scope = "visible",      -- "visible" (visible range only) | "buffer"
    scan_debounce_ms = 400,
    ui = {
      view = "picker",        -- "quickfix" forces the qf fallback
      preview = true,
      -- How long to wait after an LSP code action before re-reading the
      -- buffer. There is no completion signal to hook, so this is a guess at
      -- the server's latency -- raise it for a slow one.
      lsp_refresh_delay_ms = 500,
    },

    -- Code features
    word_split = { enable = true, min_length = 4 }, -- split CamelCase/snake_case into sub-words
    regions = { treesitter_spell = true, skip_urls = true, skip_emails = true },
    programming_dict = false, -- opt-in: technical word list (git, kubernetes, treesitter, …)
    -- Your own session word lists, e.g. domain or product vocabulary:
    -- { ["my-list"] = { "word1", "word2" } }. Like `zG`: every 'spelllang',
    -- gone on exit, your 'spellfile' untouched.
    extra_wordlists = {},

    -- Performance/safety caps
    max_highlights = 100,   -- max inline diagnostics per buffer (panel still shows all of them)
    max_file_lines = 20000, -- above this: no live scan
    skip_readonly = true,

    -- Opt-in: additionally mark issues directly in the buffer via extmark,
    -- independent of vim.diagnostic.config().
    highlights = { enable = false, style = "underline" }, -- style: "underline"|"undercurl"

    keymaps = { panel = "<leader>ss", next = "]s", fix = "<leader>z=", fix1 = "<leader>z1" },
  },
  translate = {
    engine = "google",           -- "google" (keyless) | "deepl" | "shell" | "ai" | "custom"
    fallback = { "google" },     -- engine chain used if the selected engine is unavailable or its request fails (only listed engines are tried)
    default_output = "popup",    -- popup | replace | buffer | vsplit | split | tab | insert | clipboard | notify
    default_target = nil,        -- fixed target language for motion/visual maps; nil = selection
                                 -- (the hover falls back to "EN" instead: it has nowhere to ask from)
    timeout_ms = 8000,           -- per request: a large input is split into several, each gets this budget
    max_chars = 0,               -- lower the per-request block budget in bytes (DeepL: bytes + 8 per line; 0 = provider default)
    max_blocks = 50,             -- most requests one call may need; more is refused before the first (0 = no limit)
    block_pause_ms = nil,        -- pause between the requests of one call; nil = engine default (google/shell 300 ms)
    deadline_ms = 0,             -- budget for the whole call across all its requests (0 = none)
    deepl = { api_key = nil },   -- or $DEEPL_API_KEY
    ai = { max_chars = 6000, concurrency = 2, max_total_chars = 500000 }, -- engine "ai" (ai.nvim); also provider, model, glossary, style
    -- require("language").translate_markdown(): Markdown-safe, line-true document translation
    markdown = {
      concurrency = 3,           -- requests in flight at once
      max_chars = 3000,          -- masked bytes per request
      disk_cache = true,         -- keep translated units in stdpath("cache")/language.nvim
      cache_max_kb = 2048,       -- size cap of that file, oldest entries go first
      keep = {},                 -- words that are never translated, e.g. { "Neovim" }
    },
    -- Opt-in motion/visual keymaps (off by default, to avoid claiming keys):
    --   operator: <lhs>{motion} translates the text object (e.g. gtrip)
    --   visual:   <lhs> translates the selection
    keymaps = { operator = false, visual = false },
    -- custom = { cmd = function(lines, target) return { "trans", "-b", ... } end,
    --           parse = function(out) return vim.split(out, "\n") end,
    --           max_bytes = nil },  -- raise the block budget if cmd does not put the text in argv
  },
  thesaurus = {
    enable = true,
    source = "datamuse", -- "datamuse" | "custom"
    max = 20,
    timeout_ms = 6000,
    keymap = false, -- opt-in: replace the word under the cursor with a synonym
    -- custom = function(word, cb) cb({ "syn1", "syn2" }) end,
  },

  commands = true,           -- false = register no user commands at all

  -- "Spell check this" / "Translate this" on a file or folder of a tree view
  -- (the own tree of filetree.nvim reads them from lib.nvim's registry).
  -- true: in the tree's menu and action list. A table also puts them on keys
  -- in the tree buffer: { key = { check = "<leader>sc", translate = "<leader>st" } }.
  -- false: not offered. See docs/FEATURES/SPELL.md and TRANSLATE.md.
  tree = true,
  which_key = { enable = true },

  -- One-time "which CLI tools does this plugin want, and why" popup on
  -- first setup() after install (via lib.nvim.deps). false disables it for
  -- this plugin specifically, right here in the spec passed to setup() —
  -- no vim.g needed. See README "Health".
  deps_popup = true,
})
```
