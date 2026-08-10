-- installer/http.lua
-- Download-Modul: SHA-PIN, Retries, HTML-Check, harter Request-Timeout

local M = {}

local GITHUB_COMMITS_ATOM = "https://github.com/ItIsYe/ExtreamReactor-Controller-V3/commits/beta.atom"
local GITHUB_RAW = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"
local DEFAULT_TIMEOUT_S = 20

local function extract_feed_sha(body)
  if type(body) ~= "string" then return nil end
  local sha = body:match("Grit::Commit/([0-9a-fA-F]+)")
    or body:match("/commit/([0-9a-fA-F]+)")
  if type(sha) == "string" and #sha == 40 and sha:match("^%x+$") then
    return sha:lower()
  end
  return nil
end

-- SHA ohne rate-limitierte GitHub-API aus dem oeffentlichen Commit-Feed
-- aufloesen. Der Bootstrap uebergibt den Ref normalerweise bereits; diese
-- Funktion bleibt fuer Diagnose/Legacy-Aufrufer konsistent erhalten.
function M.resolve_sha()
  if not http then return nil end
  for attempt = 1, 3 do
    local body = M.download(GITHUB_COMMITS_ATOM, { retries = 1 })
    local sha = extract_feed_sha(body)
    if sha then return sha end
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
local function read_response(r)
  -- Response-Code prüfen wenn verfügbar
  if type(r.getResponseCode) == "function" then
    local ok_code, code = pcall(r.getResponseCode)
    if ok_code and tonumber(code) ~= 200 then pcall(r.close); return nil, "HTTP " .. tostring(code) end
  end
  local ok2, body = pcall(r.readAll); pcall(r.close)
  if not ok2 or type(body) ~= "string" then return nil, "read failed" end
  return body
end

local function try_once(url, timeout_s)
  if not http then return nil, "no http" end
  timeout_s = tonumber(timeout_s) or DEFAULT_TIMEOUT_S

  if type(http.request) == "function" and os and type(os.startTimer) == "function"
      and type(os.pullEvent) == "function" then
    local call_ok, request_ok, request_err = pcall(http.request, url)
    if not call_ok or request_ok == false then
      return nil, tostring(request_err or request_ok or "http.request failed")
    end
    local timer_id = os.startTimer(timeout_s)
    while true do
      local event, p1, p2, p3 = os.pullEvent()
      if event == "http_success" and p1 == url then
        return read_response(p2)
      elseif event == "http_failure" and p1 == url then
        if p3 then pcall(p3.close) end
        return nil, tostring(p2 or "http_failure")
      elseif event == "timer" and p1 == timer_id then
        if type(http.cancel) == "function" then pcall(http.cancel, url) end
        return nil, "timeout after " .. tostring(timeout_s) .. "s"
      end
    end
  end

  if type(http.get) ~= "function" then return nil, "no http.get" end
  local ok, r = pcall(http.get, url)
  if not ok or not r then return nil, "http.get failed" end
  return read_response(r)
end

-- Download mit Retries und Cache-Busting.
-- opts: { retries=4, delays={2,5,10,20}, timeout_s=20 }
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
    local body, err = try_once(u, opts.timeout_s)
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

-- Fix (2026-07-16): CRITICAL. INSTALL-P0 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 14).
-- Diese Funktion wich bisher bei einem Fehlschlag der SHA-gepinnten URL
-- automatisch, pro Datei einzeln, auf den ungepinnten "beta"-Branch-Pfad
-- aus -- waehrend installer/init.lua das Manifest entweder ausschliesslich
-- SHA-gepinnt ODER ausschliesslich von "beta" laedt. In jeder Kombination
-- konnten so Manifest und einzelne Dateien aus zwei verschiedenen Commits
-- stammen. Jetzt wird EIN einziger, bereits vom Aufrufer entschiedener
-- Referenzpunkt ("ref": entweder eine SHA oder explizit der String
-- "beta") verwendet -- ohne eigenstaendigen Fallback hier. Der Aufrufer
-- (installer/init.lua) legt "ref" fuer den GESAMTEN Lauf einmal fest und
-- verwendet ihn sowohl fuers Manifest als auch fuer jede Datei; schlaegt
-- der Lauf komplett fehl, muss ein erneuter, komplett frischer Versuch
-- (mit neu aufgeloester SHA) gestartet werden, statt Quellen zu mischen.
function M.download_file(rel_path, ref, opts)
  local url
  if ref and ref ~= "beta" then
    url = GITHUB_RAW .. ref .. "/xreactor/" .. rel_path
  else
    url = GITHUB_RAW .. "beta/xreactor/" .. rel_path
  end
  local body, err = M.download(url, opts)
  if body then return body, url end
  return nil, "Download fehlgeschlagen fuer " .. rel_path .. ": " .. tostring(err)
end

return M
