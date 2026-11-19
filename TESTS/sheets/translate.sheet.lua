-- :Translate with the default engine (Google's keyless endpoint): the text goes to `curl` on stdin, the answer
-- replaces the lines. `curl` is answered by TESTS/sheets/fixtures/respond.lua (a fixed word list), so no request
-- leaves the machine; the start itself is the plugin's (language.util.job).
return {
  id = "language.translate",
  feature = "language.translate",
  task = "language.nvim/abnahme-prozess-features-von-hand-echtes-netz-echte-clis-off",
  title = "language.nvim: :Translate DE --output=replace buffer sends the text to the engine and replaces it",
  engine = "rpc",
  sizes = { { rows = 14, cols = 100 } },
  steps = {
    {
      lua = [[_G.L = dofile(vim.fn.getcwd() .. "/TESTS/sheets/fixtures/prepare.lua")
      _G.L.prepare({ programs = { "curl" } })
      require("language").setup({})]],
      note = "the real setup; curl answers from the fixture",
    },
    {
      lua = [[vim.cmd.edit("notes.txt")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "The quick brown fox" })]],
      note = "a text file with one English line",
    },
    { keys = ":Translate DE --output=replace buffer<CR>", note = "translate the buffer in place" },
    {
      wait = [[_G.L.text() == "Der schnelle braune Fuchs"]],
      timeout = 8000,
      note = "the translation replaced the line",
    },
    { expect = [[#_G.L.calls("curl") == 1]], note = "one request to the engine" },
    {
      expect = [[_G.L.calls("curl")[1].stdin == "The quick brown fox"]],
      note = "the text went on stdin, not on the command line",
    },
    {
      expect = [[_G.L.argv_has("curl", "translate.googleapis.com")]],
      note = "to the Google endpoint",
    },
  },
  judge = {},
  manual = {
    "Once with the real network: :Translate DE --output=replace buffer on an English line gives German text",
  },
}
