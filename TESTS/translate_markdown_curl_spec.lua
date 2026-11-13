-- TESTS/translate_markdown_curl_spec.lua -- the placeholder over the REAL curl path.
-- Spike 2026-10-06: on the Windows curl-argv path the Unicode placeholder pair
-- U+27E6/U+27E7 was destroyed for 25 % of the units (it came back as `?1?`), the
-- ASCII `{n}` for none. This spec runs the whole pipeline (registry, chunk wrapper,
-- the `custom` engine, util/job, a real curl process) against a loopback HTTP
-- server inside this Neovim, so no external network is involved. The text travels
-- as an argv element, the very path of the incident. Not applicable (n/a) without
-- curl.

return function(H)
  if vim.fn.executable("curl") ~= 1 then
    print("n/a  translate_markdown_curl_spec needs curl")
    return
  end

  -- Other specs put a stub into package.loaded["language.util.job"], and a provider keeps
  -- whichever job module it was first loaded with. This spec needs the real one, so the modules
  -- that hold it are loaded afresh here and the previous state is put back at the end.
  local touched = {
    "language.util.job",
    "language.translate.providers.custom",
    "language.translate.providers.google",
    "language.translate.providers.deepl",
    "language.translate.providers.shell",
    "language.translate.providers.registry",
  }
  local saved = {}
  for _, name in ipairs(touched) do
    saved[name] = package.loaded[name]
    package.loaded[name] = nil
  end
  local function restore()
    for _, name in ipairs(touched) do
      package.loaded[name] = saved[name]
    end
  end

  local uv = vim.uv
  local md = require("language.translate.markdown")
  local helpers = dofile(vim.fn.getcwd() .. "/TESTS/markdown_helpers.lua")

  ---@param s string
  local function url_decode(s)
    s = s:gsub("%+", " ")
    return (s:gsub("%%(%x%x)", function(h)
      return string.char(tonumber(h, 16))
    end))
  end

  local DICT = { Einleitung = "Introduction", Installation = "Setup", Verwendung = "Usage" }
  local function translate(text)
    return (
      text:gsub("%a+", function(w)
        if DICT[w] then
          return DICT[w]
        end
        if #w >= 4 then
          return w:reverse()
        end
      end)
    )
  end

  -- A loopback server: POST body `q=<urlencoded text>`, answers {"t": "<translation>"}.
  local seen = {} ---@type string[]
  local server = uv.new_tcp()
  server:bind("127.0.0.1", 0)
  local port = server:getsockname().port
  server:listen(32, function()
    local client = uv.new_tcp()
    server:accept(client)
    local buf = ""
    client:read_start(function(err, chunk)
      if err or not chunk then
        return
      end
      buf = buf .. chunk
      local head_end = buf:find("\r\n\r\n", 1, true)
      if not head_end then
        return
      end
      local len = tonumber(buf:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
      if #buf < head_end + 3 + len then
        return
      end
      local body = buf:sub(head_end + 4, head_end + 3 + len)
      local q = url_decode(body:match("^q=(.*)$") or "")
      seen[#seen + 1] = q
      local out = {}
      for _, l in ipairs(vim.split(q, "\n", { plain = true })) do
        out[#out + 1] = translate(l)
      end
      local json = vim.json.encode({ t = table.concat(out, "\n") })
      client:read_stop()
      client:write(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
          .. #json
          .. "\r\n\r\n"
          .. json,
        function()
          client:shutdown(function()
            client:close()
          end)
        end
      )
    end)
  end)

  local function stop()
    pcall(function()
      server:close()
    end)
  end

  local url = ("http://127.0.0.1:%d/"):format(port)
  local cfg = {
    engine = "custom",
    fallback = {},
    timeout_ms = 8000,
    markdown = { disk_cache = false, max_chars = 1500 },
    custom = {
      -- the text is ONE argv element (the path that destroyed the Unicode placeholder)
      cmd = function(lines)
        return {
          "curl",
          "-s",
          "-X",
          "POST",
          "--data-urlencode",
          "q=" .. table.concat(lines, "\n"),
          url,
        }
      end,
      parse = function(out)
        local ok, d = pcall(vim.json.decode, out)
        if not ok or type(d) ~= "table" or type(d.t) ~= "string" then
          error("bad response: " .. out)
        end
        return vim.split(d.t, "\n", { plain = true })
      end,
    },
  }

  local lines = helpers.fixture("readme_de.md")
  local r = { done = false }
  md.translate_markdown(lines, { target = "EN", cfg = cfg, cache = false }, function(ok, res, info)
    r.done, r.ok, r.res, r.info = true, ok, res, info
  end)
  vim.wait(30000, function()
    return r.done
  end, 5)
  stop()
  restore()

  H.ok(r.done, "the call finished")
  H.ok(r.ok, "ok: " .. tostring(r.ok and "" or r.res))
  H.ok(#seen >= 1, "curl reached the server: " .. #seen .. " request(s)")
  H.eq(r.info.failed, 0, "no unit failed over the real path: " .. vim.inspect(r.info.errors))
  H.eq(r.info.retries, 0, "and none needed a retry")
  H.eq(#r.res, #lines, "#out == #in")

  -- every placeholder arrived at the server exactly as it left, and came back
  local total, sent_placeholders = 0, 0
  for _, q in ipairs(seen) do
    total = total + #q
    for _ in q:gmatch("{%d+}") do
      sent_placeholders = sent_placeholders + 1
    end
    H.falsy(q:find("[\128-\255]"), "the request body is plain ASCII")
    H.falsy(q:find("?", 1, true) and q:find("?%d+?"), "no placeholder was turned into ?n?")
  end
  H.ok(sent_placeholders >= 10, "placeholders did travel: " .. sent_placeholders)
  for i, l in ipairs(r.res) do
    H.falsy(l:find("{%d+}") and not lines[i]:find("{%d+}"), "no placeholder left in line " .. i)
  end

  local before, after = helpers.protected(lines), helpers.protected(r.res)
  for span, n in pairs(before) do
    H.eq(after[span], n, "protected text intact after the round trip: " .. span)
  end
  H.eq(r.res[6], "# Introduction", "and it really was translated")
  local fences = helpers.fence_set(lines)
  for i in pairs(fences) do
    H.eq(r.res[i], lines[i], "fence line " .. i .. " byte-identical")
  end
  H.ok(total > 500, "a document's worth of text went through argv: " .. total .. " bytes")
end
