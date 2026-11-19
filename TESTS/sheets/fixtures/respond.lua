-- TESTS/sheets/fixtures/respond.lua -- the answering side of TESTS/sheets/fixtures/stand_ins.lua.
--
-- Run as `nvim --clean -l respond.lua <log> <program> <args...>` in place of the real program: it appends the call
-- (program, arguments, standard input, working directory) as one JSON line to <log> and prints what the real program
-- would print for the sheet's text. Nothing here reaches the network.
--
--   curl  translate.googleapis.com  the gtx answer for the text on stdin (a word list, word by word), then the status
--         api.datamuse.com          three synonyms
--   npm   root -g                   the folder of the cspell-lib stand-in (fixtures/npm-global)
--   typos --format json             one JSON line per known misspelling in the files below the working directory
--   clipboard                       nothing (the text arrived on stdin)
local log, program = arg[1], arg[2]
local args = {}
for i = 3, #arg do
  args[#args + 1] = arg[i]
end
local stdin = io.read("*a") or ""

local f = assert(io.open(log, "ab"))
f:write(
  vim.json.encode({ program = program, argv = args, stdin = stdin, cwd = vim.uv.cwd() }) .. "\n"
)
f:close()

local here = vim.fs.dirname(vim.fs.normalize(arg[0]))

local GERMAN = {
  The = "Der",
  the = "der",
  quick = "schnelle",
  brown = "braune",
  fox = "Fuchs",
  jumps = "springt",
}
local MISSPELLED = { recieve = { "receive" }, teh = { "the" } }

---@param text string
---@return string
local function to_german(text)
  return (text:gsub("%a+", GERMAN))
end

if program == "curl" then
  local url = args[#args] or ""
  if url:find("translate.googleapis.com", 1, true) then
    io.write(vim.json.encode({ { { to_german(stdin), stdin } } }) .. "\n200")
  elseif url:find("api.datamuse.com", 1, true) then
    io.write(vim.json.encode({
      { word = "speedy", score = 900 },
      { word = "rapid", score = 800 },
      { word = "fast", score = 700 },
    }))
  else
    io.stderr:write("respond.lua: no answer for " .. url .. "\n")
    os.exit(7)
  end
elseif program == "npm" then
  io.write(here .. "/npm-global\n")
elseif program == "typos" then
  for name, kind in vim.fs.dir(".", { depth = 4 }) do
    if kind == "file" then
      local lnum = 0
      for line in io.lines(name) do
        lnum = lnum + 1
        for start, word in line:gmatch("()(%a+)") do
          local fixes = MISSPELLED[word:lower()]
          if fixes then
            io.write(vim.json.encode({
              type = "typo",
              path = name,
              line_num = lnum,
              byte_offset = start - 1,
              typo = word,
              corrections = fixes,
            }) .. "\n")
          end
        end
      end
    end
  end
end
