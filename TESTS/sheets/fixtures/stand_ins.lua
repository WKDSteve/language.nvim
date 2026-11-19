-- TESTS/sheets/fixtures/stand_ins.lua -- programs of the feature sheets answered by a script, not by the network.
--
-- The plugin starts its programs as it always does (`curl` for the translation engine and the thesaurus, `typos`
-- for a project scan, `npm root -g` to find cspell for the sidecar). This chunk wraps `vim.system`: a start of one of
-- the named programs becomes `nvim -l TESTS/sheets/fixtures/respond.lua <log> <program> <args...>`, a process that
-- logs the call and prints a fixed answer (respond.lua). So the start still happens on the plugin's own line, is
-- traced and timed by `testing perf`, and no request reaches the network. A `.cmd` shim that `language.util.job` routes
-- through `cmd.exe /c <shim>` on Windows (the `typos` stand-in of `fakes`) is caught the same way.
--
-- With `clipboard = true` it also sets `g:clipboard` to a provider whose copy starts the responder with the text on
-- stdin (the way win32yank, xclip or pbcopy get it), and whose paste gives the copied text back.
--
-- A sheet loads it with `load(text, "=program stand-ins")`, never `dofile`: a chunk without a file name is runtime to
-- `testing perf`'s trace, so the plugin's own line stays the caller of the start (a `dofile` from `TESTS/` would make
-- every start the sheet's preparation).
local opts = ...

---The program a command line starts, if it is one of `opts.programs`, and where its own arguments begin.
---@param cmd any
---@return string|nil name, integer first
local function wanted(cmd)
  if type(cmd) ~= "table" or type(cmd[1]) ~= "string" then
    return nil, 0
  end
  local exe, first = cmd[1], 2
  local launcher = exe:match("[^/\\]+$"):lower()
  if
    (launcher == "cmd.exe" or launcher == "cmd")
    and cmd[2] == "/c"
    and type(cmd[3]) == "string"
  then
    exe, first = cmd[3], 4
  end
  local name = exe:match("[^/\\]+$")
  name = name:gsub("%.[eE][xX][eE]$", ""):gsub("%.[cC][mM][dD]$", ""):gsub("%.[bB][aA][tT]$", "")
  if opts.programs[name] then
    return name, first
  end
  return nil, 0
end

---@param name string
---@return string[]
local function responder(name)
  return { vim.v.progpath, "--clean", "-l", opts.responder, opts.log, name }
end

local system = vim.system
vim.system = function(cmd, sopts, on_exit)
  local name, first = wanted(cmd)
  if name then
    local argv = responder(name)
    for i = first, #cmd do
      argv[#argv + 1] = cmd[i]
    end
    cmd = argv
  end
  return system(cmd, sopts, on_exit)
end

if opts.clipboard then
  local held = { ["+"] = { { "" }, "v" }, ["*"] = { { "" }, "v" } }
  local function copy(reg)
    return function(lines, regtype)
      system(responder("clipboard"), { stdin = table.concat(lines, "\n") }):wait(10000)
      held[reg] = { lines, regtype }
    end
  end
  local function paste(reg)
    return function()
      return held[reg]
    end
  end
  vim.g.clipboard = {
    name = "sheet stand-in",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    cache_enabled = 0,
  }
end
