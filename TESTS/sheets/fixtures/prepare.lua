-- TESTS/sheets/fixtures/prepare.lua -- shared setup of the feature sheets of language.nvim.
--
-- Loaded by a `lua` step with `dofile`, from the project root. `prepare()` quiets the messages, installs the program
-- stand-ins (stand_ins.lua, loaded as a runtime chunk so the plugin's own line stays the caller of every start) and
-- moves into a fresh folder. Nothing here starts a process.
local M = {}

M.fixtures = vim.fs.normalize(vim.fn.getcwd() .. "/TESTS/sheets/fixtures")

---@param opts { programs?: string[], clipboard?: boolean }
---@return string dir  the fresh working directory
function M.prepare(opts)
  opts = opts or {}
  vim.opt.shortmess:append("I")
  vim.o.ruler = false
  vim.o.showcmd = false
  vim.o.swapfile = false
  vim.o.cmdheight = 2
  if vim.fn.exists("+messagesopt") == 1 then
    vim.o.messagesopt = "wait:0,history:500"
  end
  vim.g.lib_nvim_deps_disable_first_run = true
  M.log = vim.fs.normalize(vim.fn.tempname()) .. ".jsonl"
  M.write(M.log, "")
  local programs = {}
  for _, name in ipairs(opts.programs or {}) do
    programs[name] = true
  end
  local text = table.concat(vim.fn.readfile(M.fixtures .. "/stand_ins.lua"), "\n")
  assert(load(text, "=program stand-ins"))({
    programs = programs,
    responder = M.fixtures .. "/respond.lua",
    log = M.log,
    clipboard = opts.clipboard,
  })
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  vim.cmd.cd(vim.fn.fnameescape(dir))
  return dir
end

---Write `text` to `path` (relative to the working directory or absolute).
---@param path string
---@param text string
function M.write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---The recorded calls of the stand-ins, of `program` only when given.
---@param program? string
---@return { program: string, argv: string[], stdin: string, cwd: string }[]
function M.calls(program)
  local out = {}
  if not M.log or vim.fn.filereadable(M.log) == 0 then
    return out
  end
  for _, line in ipairs(vim.fn.readfile(M.log)) do
    if line ~= "" then
      local call = vim.json.decode(line)
      if not program or call.program == program then
        out[#out + 1] = call
      end
    end
  end
  return out
end

---Whether any argument of the first call of `program` contains `text`.
---@param program string
---@param text string
---@return boolean
function M.argv_has(program, text)
  local call = M.calls(program)[1]
  for _, a in ipairs(call and call.argv or {}) do
    if a:find(text, 1, true) then
      return true
    end
  end
  return false
end

---Whether a window on the screen shows `text`.
---@param text string
---@return boolean
function M.shown(text)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find(text, 1, true) then
        return true
      end
    end
  end
  return false
end

---Whether a window that is no file (a panel, a picker, a list: 'buftype' is set) shows `text`.
---@param text string
---@return boolean
function M.panel_shows(text)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= "" then
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(text, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

---Whether `:messages` holds `text`.
---@param text string
---@return boolean
function M.said(text)
  return vim.fn.execute("messages"):find(text, 1, true) ~= nil
end

---The text of the current buffer.
---@return string
function M.text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

return M
