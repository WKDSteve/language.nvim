-- TESTS/translate_office_spec.lua — language.translate.office: unpack, translate, pack a .pptx / .docx.
-- The archive check runs on hand-built central directories; the round trip uses the zip tools of the machine
-- (skipped, loudly, where there is none) and a fake engine.

return function(H)
  local zip = require("language.translate.office.zip")
  local office = require("language.translate.office")

  local function u16(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
  end
  local function u32(v)
    return u16(v % 65536) .. u16(math.floor(v / 65536))
  end

  -- A ZIP central directory with the given names (the content is not read by `inspect`).
  local function build(entries)
    local cd = {}
    for _, e in ipairs(entries) do
      cd[#cd + 1] = table.concat({
        "PK\1\2",
        u16(20),
        u16(20),
        u16(0),
        u16(0),
        u16(0),
        u16(0),
        u32(0),
        u32(e.size or 1),
        u32(e.size or 1),
        u16(#e.name),
        u16(0),
        u16(0),
        u16(0),
        u16(0),
        u32((e.mode or 0) * 65536),
        u32(0),
        e.name,
      })
    end
    local dir = table.concat(cd)
    return dir
      .. "PK\5\6"
      .. u16(0)
      .. u16(0)
      .. u16(#entries)
      .. u16(#entries)
      .. u32(#dir)
      .. u32(0)
      .. u16(0)
  end

  -- inspect() -----------------------------------------------------------------
  local ok_entries =
    zip.inspect(build({ { name = "a.xml", size = 10 }, { name = "d/", size = 0 } }))
  H.eq(#ok_entries, 2, "two entries")
  H.eq(ok_entries[2].dir, true, "a folder")

  local function refused(data, limits, part, label)
    local e, err = zip.inspect(data, limits)
    H.eq(e, nil, label .. ": refused")
    H.contains(err, part, label .. ": says why")
  end
  refused(build({ { name = "../evil" } }), nil, "leaves the folder", "zip slip")
  refused(build({ { name = "a/../../evil" } }), nil, "leaves the folder", "zip slip in the middle")
  refused(build({ { name = "/etc/x" } }), nil, "absolute", "absolute")
  refused(build({ { name = "C:evil" } }), nil, "absolute", "drive letter")
  refused(build({ { name = "a\\..\\b" } }), nil, "unsafe", "backslash")
  refused(build({ { name = "l", mode = 40960 + 511 } }), nil, "link", "symbolic link")
  refused(
    build({ { name = "b1", size = 1000 }, { name = "b2", size = 1000 } }),
    { max_bytes = 1500 },
    "unpacks to more",
    "bomb"
  )
  refused(
    build({ { name = "a" }, { name = "b" }, { name = "c" } }),
    { max_entries = 2 },
    "entries",
    "too many entries"
  )
  refused("garbage", nil, "not a ZIP", "not a zip")

  -- tools() --------------------------------------------------------------------
  local only_tar = zip.tools(function(n)
    return n == "tar"
  end)
  H.eq(only_tar.unpack .. only_tar.pack, "tartar", "bsdtar does both")
  H.eq(
    next(zip.tools(function()
      return false
    end)),
    nil,
    "no tool: none"
  )

  -- One Office file asks for its tools twice (unpack, then pack): `tar --version` runs once per tar, not per ask.
  do
    local real_system, real_executable, real_exepath = vim.system, vim.fn.executable, vim.fn.exepath
    local probes, tar = 0, "/opt/one/tar"
    vim.fn.executable = function(n)
      return n == "tar" and 1 or 0
    end
    vim.fn.exepath = function(n)
      return n == "tar" and tar or ""
    end
    vim.system = function(argv)
      if argv[1] == "tar" and argv[2] == "--version" then
        probes = probes + 1
      end
      return {
        wait = function()
          return { code = 0, signal = 0, stdout = "bsdtar 3.7.2 - libarchive 3.7.2\n" }
        end,
      }
    end
    local ok, err = pcall(function()
      zip._forget_tar()
      local first, second = zip.tools(), zip.tools()
      H.eq(
        first.unpack .. first.pack .. second.unpack .. second.pack,
        "tartartartar",
        "bsdtar both times"
      )
      H.eq(probes, 1, "tar --version ran once for both asks")
      tar = "/opt/other/tar"
      H.eq(zip.tools().pack, "tar", "another tar on the PATH")
      H.eq(probes, 2, "is probed again")
    end)
    vim.system, vim.fn.executable, vim.fn.exepath = real_system, real_executable, real_exepath
    zip._forget_tar()
    if not ok then
      error(err, 0)
    end
  end

  H.eq(office.output_path("C:/x/a.b.docx", "de"), "C:/x/a.b.de.docx", "output name")

  -- the round trip --------------------------------------------------------------
  local tools = zip.tools()
  if not (tools.unpack and tools.pack) then
    print("translate_office_spec: no ZIP tools on this machine, round trip skipped")
    return
  end

  local dir, cleanup = H.fixture("office")
  vim.fn.mkdir(dir .. "/src/ppt/slides", "p")
  vim.fn.mkdir(dir .. "/src/ppt/media", "p")
  vim.fn.writefile({ "<Types/>" }, dir .. "/src/[Content_Types].xml")
  vim.fn.writefile({ "PNGDATA" }, dir .. "/src/ppt/media/image1.png")
  vim.fn.writefile({
    '<p:sld><a:p><a:r><a:t>The </a:t></a:r><a:r><a:rPr b="1"/><a:t>quick</a:t></a:r><a:r><a:t> fox</a:t></a:r></a:p>'
      .. "<a:p><a:r><a:t>fox</a:t></a:r></a:p></p:sld>",
  }, dir .. "/src/ppt/slides/slide1.xml")

  local function wait(fn)
    local res
    fn(function(...)
      res = { ... }
    end)
    vim.wait(20000, function()
      return res ~= nil
    end)
    H.ok(res, "the call finished")
    return unpack(res)
  end

  local deck = dir .. "/deck.pptx"
  local packed, perr = wait(function(cb)
    zip.pack(dir .. "/src", deck, {}, cb)
  end)
  H.ok(packed, "fixture deck packed: " .. tostring(perr))

  local calls = {}
  local engine = {
    translate = function(lines, _, _, _, cb)
      calls[#calls + 1] = #lines
      local res = {}
      for i, l in ipairs(lines) do
        res[i] = l:upper()
      end
      cb(true, res)
    end,
  }

  local ok, out = wait(function(cb)
    office.translate_file(deck, "xx", { provider = engine, cfg = {} }, cb)
  end)
  H.ok(ok, "translated: " .. tostring(out))
  H.eq(out, dir .. "/deck.xx.pptx", "the copy sits next to the original")
  H.eq(calls[1], 2, "two different lines in one batch")

  local back = dir .. "/back"
  vim.fn.mkdir(back, "p")
  local unpacked, uerr = wait(function(cb)
    zip.unpack(out, back, {}, cb)
  end)
  H.ok(unpacked, "the copy is a valid archive: " .. tostring(uerr))
  local slide = H.read(back .. "/ppt/slides/slide1.xml")
  H.contains(slide, "<a:t>THE </a:t>", "first run")
  H.contains(slide, '<a:rPr b="1"/><a:t>QUICK</a:t>', "bold run kept its format")
  H.contains(slide, "<a:t> FOX</a:t>", "last run")
  H.eq(H.read(back .. "/ppt/media/image1.png"), "PNGDATA", "pictures are carried over")
  H.contains(
    H.read(dir .. "/src/ppt/slides/slide1.xml"),
    "<a:t>The </a:t>",
    "the original source is not touched"
  )

  -- refusals -------------------------------------------------------------------
  local bad, why = wait(function(cb)
    office.translate_file(dir .. "/a.txt", "xx", { provider = engine, cfg = {} }, cb)
  end)
  H.eq(bad, false, "not an Office file")
  H.contains(why, "not a PowerPoint", "says so")

  local same, swhy = wait(function(cb)
    office.translate_file(deck, "xx", { provider = engine, cfg = {}, out = deck }, cb)
  end)
  H.eq(same, false, "never overwrites the original")
  H.contains(swhy, "overwrite", "says why")

  local failing = {
    translate = function(_, _, _, _, cb)
      cb(false, "boom")
    end,
  }
  local fok, fwhy = wait(function(cb)
    office.translate_file(deck, "yy", { provider = failing, cfg = {} }, cb)
  end)
  H.eq(fok, false, "an engine failure fails the file")
  H.contains(fwhy, "boom", "with its reason")
  H.eq(vim.fn.filereadable(dir .. "/deck.yy.pptx"), 0, "and writes no copy")

  -- a cancel is heard once, stops what runs and leaves no copy ------------------------------
  local cancelled_with, cancel_calls = nil, 0
  local slow = {
    translate = function(_, _, _, _, cb)
      vim.defer_fn(function()
        cb(true, { "X", "Y" })
      end, 300)
      return { cancel = function() end }
    end,
  }
  local handle = office.translate_file(deck, "zz", { provider = slow, cfg = {} }, function(ok2, res)
    cancel_calls = cancel_calls + 1
    cancelled_with = { ok2, res }
  end)
  handle.cancel()
  vim.wait(1500, function()
    return false
  end)
  H.eq(cancel_calls, 1, "the answer comes once")
  H.eq(cancelled_with[1], false, "a cancel is a failure")
  H.eq(cancelled_with[2], "cancelled", "that says so")
  H.eq(vim.fn.filereadable(dir .. "/deck.zz.pptx"), 0, "and nothing is written")
  H.eq(vim.fn.filereadable(dir .. "/deck.zz.pptx.part.zip"), 0, "not even a half archive")

  -- a name with blanks works as any other -------------------------------------------------
  local spaced = dir .. "/my deck.pptx"
  vim.uv.fs_copyfile(deck, spaced)
  local sok, sout = wait(function(cb)
    office.translate_file(spaced, "xx", { provider = engine, cfg = {} }, cb)
  end)
  H.ok(sok, "a file name with a blank: " .. tostring(sout))
  H.eq(vim.fn.filereadable(dir .. "/my deck.xx.pptx"), 1, "the copy is there")
  H.eq(vim.fn.filereadable(dir .. "/my deck.xx.pptx.part.zip"), 0, "no half archive is left behind")

  cleanup()
end
