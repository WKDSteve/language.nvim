-- With "cspell_server" in `spell.providers.buffer` the review panel asks a long-lived node sidecar
-- (node/cspell_server.js) instead of starting cspell per check. `npm root -g` finds cspell-lib; here it is answered
-- by TESTS/sheets/fixtures/respond.lua with the folder of a cspell-lib stand-in (fixtures/npm-global), and `cspell`
-- is a stand-in on the PATH so the provider counts as installed. node and the sidecar script run for real. The
-- stand-in flags the correct word "reply", which the native check (it always runs too) passes: a finding of it can
-- only come from the sidecar.
return {
  id = "language.spell-cspell-sidecar",
  feature = "language.spell-cspell-sidecar",
  task = "language.nvim/abnahme-prozess-features-von-hand-echtes-netz-echte-clis-off",
  title = "language.nvim: <leader>ss with the cspell sidecar starts node once and shows its findings in the panel",
  engine = "rpc",
  sizes = { { rows = 16, cols = 100 } },
  fakes = { "cspell" },
  requires = { { lua = "vim.fn.executable('node') == 1", reason = "node is not installed" } },
  steps = {
    {
      lua = [[_G.L = dofile(vim.fn.getcwd() .. "/TESTS/sheets/fixtures/prepare.lua")
      _G.L.prepare({ programs = { "npm" } })
      vim.g.mapleader = " "
      require("language").setup({ spell = { providers = { buffer = { "cspell_server" } } } })]],
      note = "the real setup with the sidecar provider",
    },
    {
      lua = [[vim.cmd.edit("notes.txt")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "You will get a reply soon." })]],
      note = "a text file the native check finds nothing in",
    },
    { keys = " ss", note = "<leader>ss: the review panel of the buffer" },
    {
      wait = [[_G.L.panel_shows("reply")]],
      timeout = 10000,
      note = "the panel lists the word the sidecar flagged",
    },
    {
      expect = [[(function() local d = vim.diagnostic.get(vim.fn.bufnr("notes.txt")) return #d == 1 and d[1].user_data.word == "reply" end)()]],
      note = "the finding is marked in the buffer",
    },
    { expect = [[#_G.L.calls("npm") == 1]], note = "npm was asked once where cspell lives" },
  },
  judge = {},
  manual = {
    "Once with cspell installed globally (npm i -g cspell): the panel shows cspell's findings, a second check is instant",
  },
}
