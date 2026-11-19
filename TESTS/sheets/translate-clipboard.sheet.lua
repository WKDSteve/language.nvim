-- :Translate --output=clipboard puts the translation on the system clipboard through lib.nvim's verified writer
-- (`+` register, else xclip/wl-copy/pbcopy/PowerShell). The clipboard tool is a stand-in provider (`g:clipboard`)
-- whose copy starts a process with the text on stdin, as win32yank or xclip do; the engine's `curl` answers from the
-- fixture (TESTS/sheets/fixtures/respond.lua).
return {
  id = "language.translate-clipboard",
  feature = "language.translate-clipboard",
  task = "language.nvim/abnahme-prozess-features-von-hand-echtes-netz-echte-clis-off",
  title = "language.nvim: :Translate DE --output=clipboard buffer copies the translation to the system clipboard",
  engine = "rpc",
  sizes = { { rows = 14, cols = 100 } },
  steps = {
    {
      lua = [[_G.L = dofile(vim.fn.getcwd() .. "/TESTS/sheets/fixtures/prepare.lua")
      _G.L.prepare({ programs = { "curl" }, clipboard = true })
      require("language").setup({})]],
      note = "the real setup; a clipboard tool and curl as stand-ins",
    },
    {
      lua = [[vim.cmd.edit("notes.txt")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "The quick brown fox" })]],
      note = "a text file with one English line",
    },
    { keys = ":Translate DE --output=clipboard buffer<CR>", note = "translate to the clipboard" },
    {
      wait = [[#_G.L.calls("clipboard") >= 1]],
      timeout = 8000,
      note = "the clipboard tool was started",
    },
    {
      expect = [[_G.L.calls("clipboard")[1].stdin == "Der schnelle braune Fuchs"]],
      note = "the clipboard tool got the translation on stdin",
    },
    {
      expect = [[vim.fn.getreg("+") == "Der schnelle braune Fuchs"]],
      note = "the + register holds it",
    },
    { expect = [[_G.L.text() == "The quick brown fox"]], note = "the buffer is unchanged" },
  },
  judge = {},
  manual = {
    "Once in the real editor: :Translate DE --output=clipboard buffer, then paste in another program",
  },
}
