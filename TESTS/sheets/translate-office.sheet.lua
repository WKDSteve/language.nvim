-- :TranslateOffice unpacks a .docx with the machine's ZIP tool (unzip, else bsdtar: `tar --version` tells it from
-- GNU tar, on Windows the one in System32), sends the paragraphs to the engine and packs the translated copy
-- name.<lang>.docx next to the original. The ZIP tools run for real; the engine's `curl` answers from the fixture.
return {
  id = "language.translate-office",
  feature = "language.translate-office",
  task = "language.nvim/abnahme-prozess-features-von-hand-echtes-netz-echte-clis-off",
  title = "language.nvim: :TranslateOffice report.docx DE writes the translated copy report.DE.docx next to it",
  engine = "rpc",
  sizes = { { rows = 14, cols = 100 } },
  steps = {
    {
      lua = [[_G.L = dofile(vim.fn.getcwd() .. "/TESTS/sheets/fixtures/prepare.lua")
      local fixture = _G.L.fixtures .. "/report.docx"
      _G.L.prepare({ programs = { "curl" } })
      assert(vim.uv.fs_copyfile(fixture, "report.docx"))
      require("language").setup({})]],
      note = "the real setup; a Word file with one English paragraph in a fresh folder",
    },
    { keys = ":TranslateOffice report.docx DE<CR>", note = "translate the Word file" },
    {
      wait = [[vim.fn.filereadable("report.DE.docx") == 1]],
      timeout = 20000,
      note = "the translated copy is written",
    },
    {
      expect = [[_G.L.calls("curl")[1].stdin == "The quick brown fox"]],
      note = "the paragraph of the document went to the engine",
    },
    {
      expect = [[(function()
        local entries = require("language.translate.office.zip").inspect_file("report.DE.docx")
        for _, e in ipairs(entries or {}) do
          if e.name == "word/document.xml" then return true end
        end
        return false
      end)()]],
      note = "the copy is a ZIP archive with the document part",
    },
    { expect = [[vim.fn.filereadable("report.docx") == 1]], note = "the original is still there" },
  },
  judge = {},
  manual = {
    "Once with the real network: open report.DE.docx in Word or LibreOffice, the paragraph is German",
  },
}
