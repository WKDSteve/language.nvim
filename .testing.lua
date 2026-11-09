-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "language",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "h",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  -- ui.nvim: the spell panel / item menu and the translate window open through ui.kit (specs in TESTS/).
  deps = { "lib.nvim", "ui.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  isolated = "none",
  -- Guards (see testing.nvim's docs/GUARDS.md). Measured on this suite: every guard is clean with the
  -- allowlist below.
  guards = {
    fs = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    process_net = "error",
    -- The suite leaves no state behind: every spec that runs setup() or creates buffers, windows,
    -- :Commands, keymaps, autocmds or changes an option wraps itself in H.tracked() (TESTS/harness.lua),
    -- which puts all of it back, also when an assertion fails half-way. A spec that leaks again fails
    -- the run.
    -- (isolated = "file" stays off: spell_init_spec needs a downloaded spell file for "de" in the
    -- developer's real stdpath('data'); a hermetic child gets the "Download? [y/N]" prompt and fails.)
    state = "error",
  },
  guard_allow = {
    -- The specs create and remove fixture directories TESTS/.fixture-* inside the repository
    -- (collect, ignore, job, native, spell, translate, cspell server); relative to the project root.
    fs = { "TESTS" },
    -- Specs start headless nvim children (job stdin / sleep, version probe) to exercise the job
    -- wrapper; the nonexistent executable is the deliberate negative probe of the spawn-failure path.
    -- translate_markdown_curl_spec runs a real curl against a loopback server inside the spec's own
    -- editor (no external network): the placeholder must survive the argv path of a real process.
    -- translate_office_spec packs and unpacks a small fixture deck with the machine's zip tools.
    spawn = {
      "nvim",
      "curl",
      "zzqqxx-nonexistent-executable-language-nvim",
      "tar",
      "zip",
      "unzip",
      "7z",
    },
  },
  -- The runner counts which commands, keymaps and autocommands the specs exercise (docs/SURFACE.md of testing.nvim);
  -- `scripts/test.sh surface` compares that with surface.baseline.json (a regression gate, not a percentage).
  surface = { track = true },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = {
    gate = true,
    waivers = {},
  },
  -- The pipeline is derived (`scripts/test.sh ci list`). The GitHub workflow is generated from `workflow`:
  -- `testing init --workflow=public --force` writes it (testing.nvim docs/WORKFLOW-CI.md), the step
  -- workflow-in-sync checks it.
  ci = {
    workflow = {
      name = "language.nvim",
      layout = "hosted",
      -- the steps that depend on the platform: the windows and macOS legs run only these
      platform = { "suite", "conformance" },
      -- `testing ci land`: a check branch ci/** runs the hosted legs, main moves to a commit only once it is green there
      land = true,
    },
    steps = {
      ["workflow-in-sync"] = { preset = "workflow-in-sync" },
    },
  },
}
