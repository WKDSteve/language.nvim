---@module 'language.translate.office.zip'
---@brief Safe unpacking and packing of an Office file (a ZIP archive) with the tools the machine has.
---@description
--- The archive is looked at first, in Lua, from its central directory (no tool involved): the names, the number
--- of entries and the sizes. An archive with a name that leaves the target folder (`../x`, `/x`, `C:\x`, a
--- backslash path), a link, a ZIP64 record, more entries than `max_entries` or more unpacked bytes than
--- `max_bytes` (the "zip bomb": a few kilobytes that become gigabytes) is refused before anything is written.
--- Only then `unzip`, `tar` (bsdtar, the one Windows and macOS ship) or `7z` unpacks it, and `zip`, `tar -a` or
--- `7z` packs the result. Nothing of the archive is ever run.

local M = {}

M.max_entries = 2000
M.max_bytes = 200 * 1024 * 1024

---@internal
---@param s string
---@param at integer  -- 1-based
---@param n integer   -- 2 or 4
---@return integer
local function le(s, at, n)
  local v = 0
  for i = n, 1, -1 do
    v = v * 256 + (s:byte(at + i - 1) or 0)
  end
  return v
end

---@internal
---@param name string
---@return string|nil err
local function bad_name(name)
  if name == "" then
    return "an entry has no name"
  end
  if name:find("%z") or name:find("\\", 1, true) then
    return ("unsafe entry name %q"):format(name)
  end
  if name:sub(1, 1) == "/" or name:find("^%a:") then
    return ("absolute entry name %q"):format(name)
  end
  for seg in name:gmatch("[^/]+") do
    if seg == ".." then
      return ("entry name leaves the folder: %q"):format(name)
    end
  end
  return nil
end

---Read the central directory of a ZIP archive held in a string.
---@param data string
---@param limits? { max_entries?: integer, max_bytes?: integer }
---@return { name: string, size: integer, dir: boolean }[]|nil entries
---@return string|nil err
function M.inspect(data, limits)
  limits = limits or {}
  local max_entries = limits.max_entries or M.max_entries
  local max_bytes = limits.max_bytes or M.max_bytes

  local tail_from = math.max(1, #data - 65557)
  local eocd
  local at = #data - 21
  while at >= tail_from do
    if data:sub(at, at + 3) == "PK\5\6" then
      eocd = at
      break
    end
    at = at - 1
  end
  if not eocd then
    return nil, "not a ZIP archive (no end-of-directory record)"
  end
  local count = le(data, eocd + 10, 2)
  local cd_size = le(data, eocd + 12, 4)
  local cd_off = le(data, eocd + 16, 4)
  if count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_off == 0xFFFFFFFF then
    return nil, "ZIP64 archives are not supported"
  end
  if count > max_entries then
    return nil, ("the archive has %d entries (more than %d)"):format(count, max_entries)
  end

  local entries, total, pos = {}, 0, cd_off + 1
  for _ = 1, count do
    if data:sub(pos, pos + 3) ~= "PK\1\2" then
      return nil, "damaged central directory"
    end
    local usize = le(data, pos + 24, 4)
    local name_len = le(data, pos + 28, 2)
    local extra_len = le(data, pos + 30, 2)
    local comment_len = le(data, pos + 32, 2)
    local attr = le(data, pos + 38, 4)
    local name = data:sub(pos + 46, pos + 45 + name_len)
    if #name ~= name_len then
      return nil, "damaged central directory"
    end
    local err = bad_name(name)
    if err then
      return nil, err
    end
    if usize == 0xFFFFFFFF then
      return nil, "ZIP64 archives are not supported"
    end
    -- The Unix mode sits in the upper half of the external attributes; 0xA000 is a symbolic link.
    local mode = math.floor(attr / 65536)
    if math.floor(mode / 4096) == 10 then
      return nil, ("the entry %q is a link"):format(name)
    end
    total = total + usize
    if total > max_bytes then
      return nil,
        ("the archive unpacks to more than %d MiB"):format(math.floor(max_bytes / 1048576))
    end
    entries[#entries + 1] = { name = name, size = usize, dir = name:sub(-1) == "/" }
    pos = pos + 46 + name_len + extra_len + comment_len
  end
  return entries
end

---Inspect an archive on disk (its size is bounded before it is read).
---@param path string
---@param limits? { max_entries?: integer, max_bytes?: integer }
---@return { name: string, size: integer, dir: boolean }[]|nil entries
---@return string|nil err
function M.inspect_file(path, limits)
  local size = vim.fn.getfsize(path)
  if size < 0 then
    return nil, "cannot read " .. path
  end
  if size > ((limits and limits.max_bytes) or M.max_bytes) then
    return nil, "the file is larger than the limit"
  end
  local f = io.open(path, "rb")
  if not f then
    return nil, "cannot read " .. path
  end
  local data = f:read("*a")
  f:close()
  return M.inspect(data, limits)
end

---@internal
---What `tar --version` answered, per resolved `tar` program. The probe waits for the process, and one Office file
---asks twice (the tool to unpack, then the one to pack): `testing perf` measured two blocking starts within 300 ms.
---Keyed by the path, so a `tar` that appears on the PATH later is probed again.
---@type table<string, boolean>
local bsd_by_path = {}

---@internal
---GNU tar cannot read or write a ZIP archive (and takes `E:` for a host name); only bsdtar can.
---@return boolean
local function tar_is_bsd()
  local path = vim.fn.exepath("tar")
  if bsd_by_path[path] ~= nil then
    return bsd_by_path[path]
  end
  local ok, res = pcall(function()
    return vim.system({ "tar", "--version" }, { text = true }):wait(5000)
  end)
  if not ok or type(res) ~= "table" or res.signal ~= 0 then
    return false -- no answer (a spawn error, a timeout): asked again next time
  end
  bsd_by_path[path] = res.code == 0 and (res.stdout or ""):find("bsdtar", 1, true) ~= nil
  return bsd_by_path[path]
end

---@internal
---Forget what `tar --version` answered (specs).
function M._forget_tar()
  bsd_by_path = {}
end

---The tools to use, in order of preference.
---@param exe? fun(name: string): boolean  -- test seam; for "tar" it answers "is it bsdtar"
---@return { unpack?: string, pack?: string }
function M.tools(exe)
  exe = exe
    or function(n)
      if n == "tar" then
        return vim.fn.executable("tar") == 1 and tar_is_bsd()
      end
      return vim.fn.executable(n) == 1
    end
  local t = {}
  if exe("unzip") then
    t.unpack = "unzip"
  elseif exe("tar") then
    t.unpack = "tar"
  elseif exe("7z") then
    t.unpack = "7z"
  end
  if exe("zip") then
    t.pack = "zip"
  elseif exe("tar") then
    t.pack = "tar"
  elseif exe("7z") then
    t.pack = "7z"
  end
  return t
end

---@internal
---@param tool string
---@param file string
---@param dir string
---@return string[]
local function unpack_argv(tool, file, dir)
  if tool == "unzip" then
    return { "unzip", "-q", "-o", file, "-d", dir }
  elseif tool == "tar" then
    return { "tar", "-xf", file, "-C", dir }
  end
  return { "7z", "x", "-y", "-o" .. dir, file }
end

---@internal
---@param tool string
---@param out string
---@return string[]
local function pack_argv(tool, out)
  if tool == "zip" then
    return { "zip", "-q", "-r", "-X", out, "." }
  elseif tool == "tar" then
    return { "tar", "-a", "-cf", out, "." }
  end
  return { "7z", "a", "-tzip", "-y", out, "." }
end

M._unpack_argv = unpack_argv
M._pack_argv = pack_argv

---Unpack `file` into the empty folder `dir`, after the archive was inspected.
---@param file string
---@param dir string
---@param opts { tool?: string, limits?: table, timeout_ms?: integer, inspected?: boolean }  -- inspected: the caller looked at the archive already
---@param cb fun(ok: boolean, err?: string)
---@return { cancel: fun() }|nil job  -- nil when the call was answered at once
function M.unpack(file, dir, opts, cb)
  if not opts.inspected then
    local _, err = M.inspect_file(file, opts.limits)
    if err then
      return cb(false, err)
    end
  end
  local tool = opts.tool or M.tools().unpack
  if not tool then
    return cb(false, "no tool to unpack a ZIP archive (install unzip, bsdtar or 7z)")
  end
  return require("language.util.job").run(unpack_argv(tool, file, dir), {
    timeout_ms = opts.timeout_ms or 60000,
    on_done = function(ok, _, e)
      cb(ok, ok and nil or ("unpacking failed: " .. vim.trim(e)))
    end,
  })
end

---Pack the content of `dir` into the new archive `out`. The archive is written beside it first and moved into place
---when the tool is done, so a failed or cancelled run leaves neither a half archive nor the copy of an earlier run
---gone.
---@param dir string
---@param out string
---@param opts { tool?: string, timeout_ms?: integer }
---@param cb fun(ok: boolean, err?: string)
---@return { cancel: fun() }|nil job  -- nil when the call was answered at once
function M.pack(dir, out, opts, cb)
  local tool = opts.tool or M.tools().pack
  if not tool then
    return cb(false, "no tool to write a ZIP archive (install zip, bsdtar or 7z)")
  end
  local part = out .. ".part.zip"
  os.remove(part)
  local running = require("language.util.job").run(pack_argv(tool, part), {
    cwd = dir,
    timeout_ms = opts.timeout_ms or 60000,
    on_done = function(ok, _, e)
      if not ok then
        os.remove(part)
        return cb(false, "packing failed: " .. vim.trim(e))
      end
      local moved, why = vim.uv.fs_rename(part, out)
      if not moved then
        os.remove(part)
        return cb(false, "cannot write " .. out .. ": " .. tostring(why))
      end
      cb(true)
    end,
  })
  return {
    cancel = function()
      running.cancel()
      os.remove(part)
    end,
  }
end

return M
