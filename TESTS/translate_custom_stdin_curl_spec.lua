-- TESTS/translate_custom_stdin_curl_spec.lua -- non-ASCII text over the `custom` engine and a REAL curl.
-- Measured 2026-10-06 and 2026-10-30 (Windows 11, Neovim 0.12): an argv element `q=a ü b 中 ⟦1⟧` reaches Git for
-- Windows' curl.exe (an ANSI build, no wmain) as `a %FC b ? ?1?` -- Windows converts the UTF-16 command line to the
-- ANSI code page for such a program. C:\Windows\System32\curl.exe and a Neovim child get exact UTF-8, so the editor
-- side is right and only the program decides. The cure is the `stdin` field of the argv the `cmd` returns: stdin
-- carries the bytes as they are. This spec pins both halves against a loopback HTTP server inside this Neovim (no
-- external network). Not applicable (n/a) without curl.

return function(H)
  if vim.fn.executable("curl") ~= 1 then
    print("n/a  translate_custom_stdin_curl_spec needs curl")
    return
  end

  -- Other specs stub language.util.job; this one needs the real module (see translate_markdown_curl_spec).
  local touched = { "language.util.job", "language.translate.providers.custom" }
  local saved = {}
  for _, name in ipairs(touched) do
    saved[name] = package.loaded[name]
    package.loaded[name] = nil
  end
  local custom = require("language.translate.providers.custom")
  local job = require("language.util.job")
  for _, name in ipairs(touched) do
    package.loaded[name] = saved[name]
  end

  local TEXT = "a \u{00FC} b\n\u{4E2D}\u{6587} \u{27E6}1\u{27E7}"

  ---@param s string
  local function url_decode(s)
    s = s:gsub("%+", " ")
    return (s:gsub("%%(%x%x)", function(h)
      return string.char(tonumber(h, 16))
    end))
  end

  ---@param s string
  local function hex(s)
    return (s:gsub(".", function(ch)
      return ("%02X "):format(ch:byte())
    end))
  end

  -- Loopback server: POST body `q=<urlencoded>`, echoes the decoded value upper-cased as the answer.
  local uv = vim.uv
  local seen = {} ---@type string[]
  local server = uv.new_tcp()
  server:bind("127.0.0.1", 0)
  local port = server:getsockname().port
  server:listen(8, function()
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
      local q = url_decode(buf:sub(head_end + 4, head_end + 3 + len):match("^q=(.*)$") or "")
      seen[#seen + 1] = q
      local answer = q:upper()
      client:read_stop()
      client:write(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
          .. #answer
          .. "\r\n\r\n"
          .. answer,
        function()
          client:shutdown(function()
            client:close()
          end)
        end
      )
    end)
  end)
  local url = ("http://127.0.0.1:%d/"):format(port)

  local r = { done = false }
  custom.translate(vim.split(TEXT, "\n", { plain = true }), "EN", nil, {
    timeout_ms = 8000,
    custom = {
      cmd = function(lines)
        -- `q@-`: curl reads the value from stdin and url-encodes it.
        return {
          "curl",
          "-s",
          "-X",
          "POST",
          "--data-urlencode",
          "q@-",
          url,
          stdin = table.concat(lines, "\n"),
        }
      end,
    },
  }, function(ok, res)
    r.done, r.ok, r.res = true, ok, res
  end)
  vim.wait(15000, function()
    return r.done
  end, 5)

  -- The editor's half: a UTF-8 aware child (Neovim) gets the argv element byte-exact.
  local echo = { done = false }
  job.run({ "nvim", "--headless", "-u", "NONE", "-l", "-", TEXT }, {
    timeout_ms = 15000,
    stdin = "io.write(arg[1])",
    on_done = function(ok, out)
      echo.done, echo.ok, echo.out = true, ok, out
    end,
  })
  vim.wait(20000, function()
    return echo.done
  end, 5)
  pcall(function()
    server:close()
  end)

  H.ok(r.done, "the custom call finished")
  H.ok(r.ok, "and succeeded: " .. vim.inspect(r.res))
  H.eq(#seen, 1, "curl reached the server once")
  H.eq(
    hex(seen[1] or ""),
    hex(TEXT),
    "umlaut, CJK and the placeholder pair arrive as UTF-8 via the stdin field"
  )
  H.eq(table.concat(r.res or {}, "\n"), TEXT:upper(), "and the answer comes back line by line")

  H.ok(echo.done and echo.ok, "the nvim child ran")
  H.eq(hex(echo.out or ""), hex(TEXT), "an argv element leaves the editor as exact UTF-8")
end
