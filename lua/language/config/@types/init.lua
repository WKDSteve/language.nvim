---@meta
---@module 'language.config.@types'
---@brief Type definitions for the language.nvim configuration tree.
---@description
--- The config is split into two independent domain subtrees (`spell`,
--- `translate`) plus a couple of top-level switches. See config/DEFAULTS.lua
--- for the concrete default values.

-- #####################################################################
-- Spell subtree
-- #####################################################################

---@class LanguageSpellProvidersCfg : LanguageSpellProvidersOpts
---@field order  string[]                       -- provider resolution order
---@field buffer string[]                       -- providers used for buffer/visible scope
---@field cwd    string[]                        -- providers used for cwd/path scope (CLI preferred)
---@field native { spelllang: string|nil }       -- nil = inherit vim 'spelllang'
---@field lsp    { enable: boolean, servers: string[] }
---@field custom LanguageSpellCustomProviderCfg|nil

---@class LanguageSpellCustomProviderCfg
---@field cmd   fun(scope: LanguageScope, cfg: LanguageSpellCfg): string[]
---@field parse fun(out: string, base: string|nil): table[]

---@class LanguageSpellWordSplitCfg : LanguageSpellWordSplitOpts
---@field enable     boolean                     -- split CamelCase/snake_case into subwords
---@field min_length integer                     -- ignore subwords shorter than this

---@class LanguageSpellRegionsCfg : LanguageSpellRegionsOpts
---@field treesitter_spell boolean               -- only check Treesitter @spell regions when available
---@field skip_urls        boolean
---@field skip_emails      boolean

---@class LanguageSpellDictionaryCfg : LanguageSpellDictionaryOpts
---@field ignore_file   string                   -- persistent ignore list path
---@field use_spellfile boolean                  -- also write to nvim spellfile on add-to-dict
---@field replace_all   boolean                  -- apply a chosen suggestion to all identical errors in scope

---@class LanguageSpellUiCfg : LanguageSpellUiOpts
---@field view     "picker"|"select"|"quickfix"
---@field preview  boolean
---@field group_by "file"|"none"
---@field dedupe   boolean
---@field lsp_refresh_delay_ms integer  Wait after an LSP code action before re-reading the buffer, in ms (default 500)

---@class LanguageSpellHighlightsCfg : LanguageSpellHighlightsOpts
---@field enable boolean
---@field style  "underline"|"undercurl"

---@class LanguageSpellCfg : LanguageSpellOpts
---@field providers        LanguageSpellProvidersCfg
---@field filetypes        string[]
---@field default_scope    LanguageScopeKind
---@field live             boolean
---@field live_scope       LanguageScopeKind
---@field scan_debounce_ms integer
---@field word_split       LanguageSpellWordSplitCfg
---@field max_highlights   integer
---@field max_file_lines   integer
---@field skip_readonly    boolean
---@field regions          LanguageSpellRegionsCfg
---@field programming_dict boolean
---@field extra_wordlists  table<string, string[]>
---@field ui               LanguageSpellUiCfg
---@field dictionary       LanguageSpellDictionaryCfg
---@field guard            { block_write_on_error: boolean }
---@field highlights       LanguageSpellHighlightsCfg
---@field keymaps          LanguageSpellKeymaps

-- #####################################################################
-- Translate subtree
-- #####################################################################

---@alias LanguageTranslateOutput
---| "popup"    # default: read-only kit popup near the cursor (ui.kit)
---| "replace"  # overwrite the source range in place
---| "buffer"   # open the translation in a new unnamed buffer
---| "vsplit"   # like "buffer", in a new vertical split
---| "split"    # like "buffer", in a new horizontal split
---| "tab"      # like "buffer", in a new tab
---| "insert"   # insert just below the source range
---| "clipboard" # copy to the system clipboard (and unnamed register)
---| "notify"   # show via vim.notify
---@alias LanguageTranslateInput  "selection"|"clipboard"|"input"

---@class LanguageTranslateCfg : LanguageTranslateOpts
---@field engine         string                  -- "google"|"deepl"|"shell"|<custom key>
---@field fallback       string[]                -- engine fallback chain
---@field default_output LanguageTranslateOutput
---@field default_input  LanguageTranslateInput
---@field default_langs  string[]
---@field default_target string|nil              -- fixed target for motion/visual maps; nil = prompt. `language.hover` falls back to "EN" instead, because a hover has nowhere to ask from.
---@field nocode_default boolean
---@field timeout_ms     integer
---@field max_chars      integer                 -- lowers the per-request block budget (bytes, DeepL: bytes + 8 per line); 0 = provider default
---@field max_blocks     integer                 -- most requests one call may need (an input that needs more is refused up front); 0 = no limit
---@field run_id? string|integer              -- set per run by `translate_markdown` and the chunk wrapper, never configured: calls with the same id are one run for the ai engine's bulk budget
---@field block_pause_ms? integer                -- pause between the requests of one call; nil = engine default (google/shell 300, others 0)
---@field deadline_ms    integer                 -- budget for the whole call across its requests; 0 = none
---@field deepl          { api_key: string|nil }
---@field ai             LanguageTranslateAiCfg
---@field custom         LanguageTranslateCustomProviderCfg|nil
---@field markdown       LanguageTranslateMarkdownCfg
---@field keymaps        LanguageTranslateKeymaps
---@field history        { enable: boolean, max: integer, persist: boolean, file: string }
---@field files          { output: "suffix"|"replace"|"buffers", extensions: string[], max_kb: integer }

-- #####################################################################
-- Root
-- #####################################################################

---@class LanguageThesaurusCfg : LanguageThesaurusOpts
---@field enable     boolean
---@field source     "datamuse"|"custom"
---@field max        integer
---@field timeout_ms integer
---@field keymap     string|string[]|false  # `replace`: synonyms for the word under the cursor
---@field custom     fun(word: string, cb: fun(synonyms: string[]))|nil

---@class LanguageConfig : LanguageOpts
---@field hover boolean # Register the `on_request` position preview with hover.nvim, so `:Hover show` over a word answers with its translation. Default true, and a no-op without hover.nvim installed. `false` registers nothing at all.
---@field spell      LanguageSpellCfg
---@field translate  LanguageTranslateCfg
---@field thesaurus  LanguageThesaurusCfg
---@field commands   boolean
---@field keymaps    { enable: boolean }  # `false` (setup: `keymaps = false`) binds no keymap at all
---@field which_key  { enable: boolean }
---@field tree       boolean|Language.Tree.Opts  # "Spell check this" / "Translate this" on a node of a tree view (default true: offered without a key), see language.integrations.tree
---@field deps_popup? boolean  # Show the lib.nvim.deps "declared tools" popup once, ever, on first setup() after install (default true; needs lib.nvim.deps — a no-op without it)

--- What `setup()` accepts: the shape of `LanguageConfig` with every field
--- optional, nested tables included. The resolved `LanguageConfig` stays
--- strict, so a partial call is legal without every read of
--- `cfg.spell.live` becoming a nil check.
---@class LanguageOpts
---@field hover? boolean # Register the `on_request` position preview with hover.nvim, so `:Hover show` over a word answers with its translation. Default true, and a no-op without hover.nvim installed. `false` registers nothing at all.
---@field spell?      LanguageSpellOpts
---@field translate?  LanguageTranslateOpts
---@field thesaurus?  LanguageThesaurusOpts
---@field commands?   boolean
---@field keymaps?    boolean|{ enable?: boolean }  # `false` binds no keymap at all
---@field which_key?  { enable: boolean }
---@field tree?       boolean|Language.Tree.Opts  # "Spell check this" / "Translate this" on a node of a tree view (default true: offered without a key); `{ key = { check = "<lhs>", translate = "<lhs>" } }` also puts them on keys in the tree buffer, `false` does not offer them
---@field deps_popup? boolean  # Show the lib.nvim.deps "declared tools" popup once, ever, on first setup() after install (default true; needs lib.nvim.deps — a no-op without it)

---@class LanguageSpellOpts
---@field providers?        LanguageSpellProvidersOpts
---@field filetypes?        string[]
---@field default_scope?    LanguageScopeKind
---@field live?             boolean
---@field live_scope?       LanguageScopeKind
---@field scan_debounce_ms? integer
---@field word_split?       LanguageSpellWordSplitOpts
---@field max_highlights?   integer
---@field max_file_lines?   integer
---@field skip_readonly?    boolean
---@field regions?          LanguageSpellRegionsOpts
---@field programming_dict? boolean
---@field extra_wordlists?  table<string, string[]>
---@field ui?               LanguageSpellUiOpts
---@field dictionary?       LanguageSpellDictionaryOpts
---@field guard?            { block_write_on_error: boolean }
---@field highlights?       LanguageSpellHighlightsOpts
---@field keymaps?          LanguageSpellKeymaps

---@class LanguageSpellUiOpts
---@field view?                 "picker"|"select"|"quickfix"
---@field preview?              boolean
---@field group_by?             "file"|"none"
---@field dedupe?               boolean
---@field lsp_refresh_delay_ms? integer  Wait after an LSP code action before re-reading the buffer, in ms (default 500)

---@class LanguageSpellProvidersOpts
---@field order?  string[]                       -- provider resolution order
---@field buffer? string[]                       -- providers used for buffer/visible scope
---@field cwd?    string[]                        -- providers used for cwd/path scope (CLI preferred)
---@field native? { spelllang: string|nil }       -- nil = inherit vim 'spelllang'
---@field lsp?    { enable: boolean, servers: string[] }
---@field custom? LanguageSpellCustomProviderCfg|nil

---@class LanguageSpellWordSplitOpts
---@field enable?     boolean                     -- split CamelCase/snake_case into subwords
---@field min_length? integer                     -- ignore subwords shorter than this

---@class LanguageSpellRegionsOpts
---@field treesitter_spell? boolean               -- only check Treesitter @spell regions when available
---@field skip_urls?        boolean
---@field skip_emails?      boolean

---@class LanguageSpellDictionaryOpts
---@field ignore_file?   string                   -- persistent ignore list path
---@field use_spellfile? boolean                  -- also write to nvim spellfile on add-to-dict
---@field replace_all?   boolean                  -- apply a chosen suggestion to all identical errors in scope

---@class LanguageSpellHighlightsOpts
---@field enable? boolean
---@field style?  "underline"|"undercurl"

---@class LanguageTranslateAiCfg
---@field provider?        string                    -- ai.nvim provider id; nil = ai.nvim's own choice (`provider`/`auto`)
---@field model?           string                    -- model; nil = ai.nvim's configured one
---@field glossary?        table<string|integer, string> -- `{ term = "translation" }`, or a list of terms kept as they are
---@field style?           string                    -- tone, e.g. "formal, second person"
---@field max_chars        integer                   -- largest request (prompt + system) in characters
---@field concurrency      integer                   -- requests in flight per run (1-16)
---@field max_total_chars  integer|false             -- cumulative characters per run; false = no cap

---@class LanguageTranslateAiOpts
---@field provider?        string
---@field model?           string
---@field glossary?        table<string|integer, string>
---@field style?           string
---@field max_chars?       integer
---@field concurrency?     integer
---@field max_total_chars? integer|false

---@class LanguageTranslateMarkdownCfg
---@field concurrency  integer    -- requests in flight at once (1-16)
---@field max_chars    integer    -- masked bytes per request
---@field disk_cache   boolean    -- persist the unit cache in stdpath("cache")/language.nvim
---@field cache_max_kb integer    -- size cap of the cache file
---@field cache_dir?   string     -- directory of the cache file instead of stdpath("cache")/language.nvim
---@field keep         string[]   -- words that are never translated

---@class LanguageTranslateMarkdownOpts
---@field concurrency?  integer
---@field max_chars?    integer
---@field disk_cache?   boolean
---@field cache_max_kb? integer
---@field cache_dir?     string
---@field keep?         string[]

---@class LanguageTranslateOpts
---@field engine?         string                  -- "google"|"deepl"|"shell"|<custom key>
---@field fallback?       string[]                -- engine fallback chain
---@field default_output? LanguageTranslateOutput
---@field default_input?  LanguageTranslateInput
---@field default_langs?  string[]
---@field default_target? string|nil              -- fixed target for motion/visual maps; nil = prompt
---@field nocode_default? boolean
---@field timeout_ms?     integer
---@field max_chars?      integer                 -- lowers the per-request block budget (bytes, DeepL: bytes + 8 per line); 0 = provider default
---@field max_blocks?     integer                 -- most requests one call may need (an input that needs more is refused up front); 0 = no limit
---@field block_pause_ms? integer                 -- pause between the requests of one call; nil = engine default (google/shell 300, others 0)
---@field deadline_ms?    integer                 -- budget for the whole call across its requests; 0 = none
---@field deepl?          { api_key: string|nil }
---@field ai?             LanguageTranslateAiOpts
---@field custom?         LanguageTranslateCustomProviderCfg|nil
---@field keymaps?        LanguageTranslateKeymaps
---@field history?        { enable: boolean, max: integer, persist: boolean, file: string }
---@field files?          { output: "suffix"|"replace"|"buffers", extensions: string[], max_kb: integer }

---@class LanguageThesaurusOpts
---@field enable?     boolean
---@field source?     "datamuse"|"custom"
---@field max?        integer
---@field timeout_ms? integer
---@field keymap?     string|string[]|false  # `replace`: synonyms for the word under the cursor
---@field custom?     fun(word: string, cb: fun(synonyms: string[]))|nil
return {}

-- #####################################################################
-- Keymap tables
--
-- Every field is one lhs, a list of them, or `false`/unset for "do not bind".
-- The field name is the action name the registry reports typos against, so a
-- misspelled key says so instead of silently binding nothing.

--- `panel` is global; `fix`, `fix1` and `next` are buffer-local and exist
--- only while a spell session is running on that buffer.
---@class LanguageSpellKeymaps
---@field panel? string|string[]|false  # toggle the spell session (default `<leader>ss`)
---@field fix?   string|string[]|false  # correct word & advance (default `<leader>z=`)
---@field fix1?  string|string[]|false  # accept first suggestion & advance (default `<leader>z1`)
---@field next?  string|string[]|false  # next spell error (default `]s`)

---@class LanguageTranslateCustomProviderCfg
---@field cmd       fun(lines: string[], target: string, source: string|nil): string[]
---@field parse     fun(out: string): string[]
---@field max_bytes? integer  -- block budget in bytes when `cmd` does not put the text in argv (default 6000 on Windows, 20000 elsewhere)

--- All opt-in: unset by default, so nothing of yours is clobbered.
---
--- `to` is one key per language, working in both normal (operator) and visual
--- mode -- a count cannot carry the language on an operator, where it belongs
--- to the motion.
---@class LanguageTranslateKeymaps
---@field operator? string|string[]|false  # `<lhs>{motion}` translates the moved-over text
---@field visual?   string|string[]|false  # translate the visual selection
---@field to?       table<string, string|string[]|false>  # e.g. `{ EN = "<leader>te" }`
