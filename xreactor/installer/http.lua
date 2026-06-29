-- installer/http.lua
-- Download-Modul: SHA-PIN, Retries, HTML-Check
-- CC:Tweaked kompatibel: http.get(url) ohne timeout-Parameter

local M = {}

local GITHUB_API = "https://api.github.com/repos/ItIsYe/ExtreamReactor-Controller-V3/branches/beta"
local GITHUB_RAW = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"

-- SHA auflösen (3 Versuche)
function M.resolve_sha()
  if not http or type(http.get) ~= "function" then return nil end
  for attempt = 1, 3 do
    local ok, r = pcall(http.get, GITHUB_API)
    if ok and r then
      local ok2, body = pcall(r.readAll); pcall(r.close)
      if ok2 and type(body) == "string" then
        local sha = body:match('"sha"%s*:%s*"(%x+)"')
        if sha then return sha end
      end
    end
    if attempt < 3 then os.sleep(3) end
  end
  return nil
end

-- HTML-Erkennung (CDN-Fehlerseiten)
function M.is_html(body)
  if type(body) ~= "string" then return false end
  local s = body:sub(1, 200):lower()
  return s:find("<html", 1, true) ~= nil or s:find("<!doctype", 1, true) ~= nil
end

-- Einfacher synchroner Download einer URL.
-- Gibt body oder nil, err zurück.
local function try_once(url)
  if not http or type(http.get) ~= "function" then return nil, "no http" end
  local ok, r = pcall(http.get, url)
  if not ok or not r then return nil, "http.get failed" end
  -- Response-Code prüfen wenn verfügbar
  if type(r.getResponseCode) == "function" then
    local code = r.getResponseCode()
    if code ~= 200 then pcall(r.close); return nil, "HTTP " .. tostring(code) end
  end
  local ok2, body = pcall(r.readAll); pcall(r.close)
  if not ok2 or type(body) ~= "string" then return nil, "read failed" end
  return body
end

-- Download mit Retries und Cache-Busting.
-- opts: { retries=4, delays={2,5,10,20} }
function M.download(url, opts)
  opts = opts or {}
  local retries = opts.retries or 4
  local delays  = opts.delays  or {2, 5, 10, 20}
  local last_err
  for attempt = 1, retries do
    -- Cache-Bust
    local sep = url:find("?", 1, true) and "&" or "?"
    local t   = tostring(os.epoch and os.epoch("utc") or os.time())
    local u   = url .. sep .. "xr_cb=" .. attempt .. "_" .. t
    local body, err = try_once(u)
    if body then
      if M.is_html(body) then
        last_err = "unexpected HTML (CDN error)"
      else
        return body, url
      end
    else
      last_err = err
    end
    if attempt < retries then
      os.sleep(delays[attempt] or 20)
    end
  end
  return nil, tostring(last_err or "download failed after " .. retries .. " retries")
end

-- Lädt eine Datei aus dem xreactor-Verzeichnis des Repos.
-- SHA-URL zuerst, Branch-URL als Fallback.
function M.download_file(rel_path, sha, opts)
  local urls = {}
  if sha then
    urls[1] = GITHUB_RAW .. sha  .. "/xreactor/" .. rel_path
    urls[2] = GITHUB_RAW .. "beta/xreactor/" .. rel_path
  else
    urls[1] = GITHUB_RAW .. "beta/xreactor/" .. rel_path
  end
  local last_err
  for _, url in ipairs(urls) do
    local body, err = M.download(url, opts)
    if body then return body, url end
    last_err = err
  end
  return nil, "alle URLs fehlgeschlagen fuer " .. rel_path .. ": " .. tostring(last_err)
end

return M
