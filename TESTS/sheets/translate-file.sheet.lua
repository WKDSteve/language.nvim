-- :Translate <lang> path=<file> translates a whole file into a sibling name.<LANG>.ext (the default `files.output`
-- "suffix"); a Markdown file goes through the masked document translation. The engine's `curl` answers from the
-- fixture (TESTS/sheets/fixtures/respond.lua).
return {
  id = "language.translate-file",
  feature = "language.translate-file",
  title = "language.nvim: :Translate DE path=notes.md writes the translated notes.DE.md next to it",
  engine = "rpc",
  sizes = { { rows = 14, cols = 100 } },
  steps = {
    {
      lua = [[_G.L = dofile(vim.fn.getcwd() .. "/TESTS/sheets/fixtures/prepare.lua")
      _G.L.prepare({ programs = { "curl" } })
      _G.L.write("notes.md", "# Notes\n\nThe quick brown fox\n")
      require("language").setup({ translate = { markdown = { disk_cache = false } } })]],
      note = "the real setup; a Markdown file in a fresh folder",
    },
    { keys = ":Translate DE path=notes.md<CR>", note = "translate the file" },
    {
      wait = [[vim.fn.filereadable("notes.DE.md") == 1]],
      timeout = 10000,
      note = "the translated sibling is written",
    },
    {
      expect = [[table.concat(vim.fn.readfile("notes.DE.md"), "\n"):find("Der schnelle braune Fuchs", 1, true) ~= nil]],
      note = "it holds the translation",
    },
    { expect = [[#_G.L.calls("curl") >= 1]], note = "the engine was asked" },
  },
  judge = {},
  manual = {
    "Once with the real network: :Translate DE path=README.md writes README.DE.md in German",
  },
}
