-- TESTS/sheets/features.lua -- the functionalities of language.nvim that start a process (directly or through
-- lib.nvim), read by testing.nvim (`testing perf`, `testing sheets report`). A feature sheet names its entry with
-- `feature = "<id>"`; an entry without a sheet says why with `perf`.
--
-- The network (Google, Datamuse) and the CLIs that are not on every machine (typos, cspell's global install) are
-- answered by TESTS/sheets/fixtures/respond.lua through TESTS/sheets/fixtures/stand_ins.lua: the start still happens
-- on the plugin's own line. The ZIP tools, node and the sidecar script run for real.
return {
  {
    id = "language.translate",
    title = ":Translate sends the text of a range to the translation engine (curl, text on stdin) and shows or replaces the result",
    surface = { "command:Translate", "command:TranslateReplace", "api:language.translate" },
    docs = "docs/FEATURES/TRANSLATE.md",
  },
  {
    id = "language.translate-clipboard",
    title = ":Translate --output=clipboard copies the translation to the system clipboard (+ register, else xclip/wl-copy/pbcopy/PowerShell)",
    surface = { "command:Translate", "config:translate.default_output" },
    docs = "docs/FEATURES/TRANSLATE.md",
  },
  {
    id = "language.translate-file",
    title = ":Translate <lang> path=<file> translates a whole file into a sibling name.<LANG>.ext (Markdown masked)",
    surface = { "command:Translate", "config:translate.files", "api:language.translate_markdown" },
    docs = "docs/FEATURES/TRANSLATE.md",
  },
  {
    id = "language.translate-office",
    title = ":TranslateOffice unpacks a .docx/.pptx with unzip/bsdtar/7z, translates its paragraphs and packs the copy name.<lang>.ext",
    surface = { "command:TranslateOffice" },
    docs = "docs/FEATURES/TRANSLATE.md",
  },
  {
    id = "language.translate-deepl",
    title = "The DeepL engine (translate.engine = 'deepl'): the same curl request with the API key on stdin",
    surface = { "config:translate.engine", "config:translate.deepl" },
    docs = "docs/FEATURES/TRANSLATE.md",
    perf = "manual:needs a DeepL account (API key); its start is the language.util.job line of language.translate",
  },
  {
    id = "language.translate-shell",
    title = "The translate-shell engine (translate.engine = 'shell'): `trans` per block",
    surface = { "config:translate.engine" },
    docs = "docs/FEATURES/TRANSLATE.md",
    perf = "skip:trans is on few machines and none of the CI runners; its start is the language.util.job line of language.translate",
  },
  {
    id = "language.translate-custom",
    title = "A custom translation command (translate.custom.cmd): the user's own argv per block",
    surface = { "config:translate.custom" },
    docs = "docs/configuration.md",
    perf = "skip:the program is the user's own; its start is the language.util.job line of language.translate",
  },
  {
    id = "language.thesaurus",
    title = "The thesaurus key replaces the word under the cursor with a synonym from Datamuse (curl)",
    surface = { "config:thesaurus.keymap" },
    docs = "docs/FEATURES/THESAURUS.md",
  },
  {
    id = "language.spell-project",
    title = ":Spellcheck cwd / path=<dir> scans a project with the first external CLI of spell.providers.cwd (typos) and opens the review panel",
    surface = { "command:Spellcheck", "config:spell.providers.cwd" },
    docs = "docs/FEATURES/SPELL.md",
  },
  {
    id = "language.spell-cli-oneshot",
    title = "The other project scanners in spell.providers.cwd: cspell, codespell or a custom CLI, one process per scan",
    surface = { "config:spell.providers.cwd", "config:spell.providers.custom" },
    docs = "docs/FEATURES/SPELL.md",
    perf = "skip:the same language.util.job start as language.spell-project, only the program differs",
  },
  {
    id = "language.spell-cspell-sidecar",
    title = "With cspell_server in spell.providers.buffer the review panel asks a long-lived node sidecar (found through npm root -g)",
    surface = { "binding:<leader>ss", "config:spell.providers.buffer" },
    docs = "docs/FEATURES/SPELL.md",
  },
  {
    id = "language.hover-translate",
    title = ":Hover show over a word answers with its translation (a hover.nvim preview, the engine's curl request)",
    surface = { "config:hover" },
    docs = "docs/FEATURES/HOVER.md",
    -- hover.nvim is no dependency of the sheets' minimal init; the installed config has both.
    perf = "user",
  },
  {
    id = "language.tree-actions",
    title = "'Spell check this' and 'Translate this' on a node of a tree view (filetree.nvim)",
    surface = { "config:tree" },
    docs = "docs/FEATURES/CORE.md",
    -- The tree is filetree.nvim's, only in the installed config; the starts are those of language.spell-project and
    -- language.translate-file.
    perf = "user",
  },
}
