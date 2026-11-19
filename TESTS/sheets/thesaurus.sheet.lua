-- The thesaurus key with a count takes that synonym of the word under the cursor straight away (like `3z=`): the
-- synonyms come from Datamuse through `curl`, answered here by the fixture (TESTS/sheets/fixtures/respond.lua).
return {
  id = "language.thesaurus",
  feature = "language.thesaurus",
  task = "language.nvim/abnahme-prozess-features-von-hand-echtes-netz-echte-clis-off",
  title = "language.nvim: 1<leader>th on a word replaces it with its first synonym from Datamuse",
  engine = "rpc",
  sizes = { { rows = 14, cols = 100 } },
  steps = {
    {
      lua = [[_G.L = dofile(vim.fn.getcwd() .. "/TESTS/sheets/fixtures/prepare.lua")
      _G.L.prepare({ programs = { "curl" } })
      vim.g.mapleader = " "
      require("language").setup({ thesaurus = { keymap = "<leader>th" } })]],
      note = "the real setup with the thesaurus key; curl answers from the fixture",
    },
    {
      lua = [[vim.cmd.edit("notes.txt")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "The quick brown fox" })
      vim.api.nvim_win_set_cursor(0, { 1, 5 })]],
      note = "a line of text, the cursor on 'quick'",
    },
    { keys = "1 th", note = "1<leader>th: take the first synonym" },
    {
      wait = [[_G.L.text() == "The speedy brown fox"]],
      timeout = 8000,
      note = "the word is replaced by the first synonym",
    },
    {
      expect = [[_G.L.argv_has("curl", "rel_syn=quick")]],
      note = "Datamuse was asked for synonyms of the word under the cursor",
    },
  },
  judge = {},
  manual = {
    "Once with the real network: <leader>th on an English word opens a menu of synonyms",
  },
}
