-- :Spellcheck cwd scans the whole project with the first external CLI of `spell.providers.cwd` (typos by default)
-- and opens the review panel. `typos` is a stand-in on the PATH (`fakes`, so the provider finds it) whose start is
-- answered by TESTS/sheets/fixtures/respond.lua: one JSON line per known misspelling in the files below.
return {
  id = "language.spell-project",
  feature = "language.spell-project",
  title = "language.nvim: :Spellcheck cwd runs typos over the project and lists the misspelling in the panel",
  engine = "rpc",
  sizes = { { rows = 16, cols = 100 } },
  fakes = { "typos" },
  steps = {
    {
      lua = [[_G.L = dofile(vim.fn.getcwd() .. "/TESTS/sheets/fixtures/prepare.lua")
      _G.L.prepare({ programs = { "typos" } })
      vim.fn.mkdir("docs", "p")
      _G.L.write("docs/guide.md", "# Guide\n\nYou will recieve a reply.\n")
      _G.L.write("README.md", "# Project\n\nNothing wrong here.\n")
      require("language").setup({})]],
      note = "the real setup; a project with one misspelling in docs/guide.md",
    },
    { keys = ":Spellcheck cwd<CR>", note = "scan the project" },
    {
      wait = [[_G.L.panel_shows("recieve")]],
      timeout = 8000,
      note = "the panel lists the misspelled word",
    },
    {
      expect = [[_G.L.argv_has("typos", "json")]],
      note = "typos was asked for its JSON output",
    },
    {
      expect = [[vim.uv.fs_realpath(_G.L.calls("typos")[1].cwd) == vim.uv.fs_realpath(vim.fn.getcwd())]],
      note = "in the project folder",
    },
  },
  judge = {},
  manual = {
    "Once with typos installed: :Spellcheck cwd in a real project lists its typos in the panel",
  },
}
