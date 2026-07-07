-- installer/auto_update.lua
-- Periodischer Versions-Check und automatisches Update.
-- Läuft OHNE Bootstrap — nur fs, http, os, print verfügbar.

local M = {}

local ARMING_PATH   = "/xreactor/config/remote_update.lua"
local RELEASE_PATH  = "/xreactor/release.lua"
local GITHUB_API    = "https://api.github.com/repos/ItIsYe/ExtreamReactor-Controller-V3/branches/beta"
local GITHUB_RAW    = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"

local function log(msg) pcall(print, "[AUTO] " .. tostring(msg)) end

-- HTTP-Download parallel-sicher:
-- Nutzt http.request (async) + wartet auf http_success/http_failure Event.
-- Andere Coroutinen sehen alle anderen Events weiterhin.
local function http_get_async(url)
  if not http or type(http.request) ~= "function" then
    -- Fallback: synchrones http.get (funktioniert nur ohne parallel)
    local ok, r = pcall(http.get, url)
    if not ok or not r then return nil, "http.get failed" end
    local ok2, body = pcall(r.readAll); pcall(r.close)
    if ok2 and type(body) == "string" then return body end
    return nil, "readAll failed"
  end
  -- Async-Pfad: http.request + Event warten
  local ok_req = pcall(http.request, url)
  if not ok_req then return nil, "http.request failed" end
  -- Warte auf http_success oder http_failure für diese URL
  -- Timeout: 300 Ticks = 15 Sekunden
  local timer = os.startTimer(15)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "http_success" and p1 == url then
      if p2 then
        local ok2, body = pcall(p2.readAll); pcall(p2.close)
        if ok2 and type(body) == "string" and #body > 0 then
          return body
        end
        return nil, "readAll failed"
      end
      return nil, "empty response"
    elseif ev == "http_failure" and p1 == url then
      if p3 then pcall(p3.close) end
      return nil, tostring(p2 or "http_failure")
    elseif ev == "timer" and p1 == timer then
      return nil, "timeout"
    end
    -- Alle anderen Events ignorieren (andere Coroutinen kriegen sie trotzdem)
  end
end

local function arming()
  if not fs or not fs.exists(ARMING_PATH) then
    log("Config fehlt: " .. ARMING_PATH)
    return nil
  end
  local f = fs.open(ARMING_PATH, "r"); if not f then return nil end
  local src = f.readAll(); f.close()
  -- _ENV statt {} damit return in der Config funktioniert
  local loader, lerr = load(src, "=arm", "t", _ENV)
  if not loader then
    log("Config Parse-Fehler: " .. tostring(lerr)); return nil
  end
  local ok, cfg = pcall(loader)
  if not ok then log("Config Fehler: " .. tostring(cfg)); return nil end
  if type(cfg) ~= "table" then log("Config kein Table: " .. type(cfg)); return nil end
  if cfg.enabled ~= true then log("Config: enabled=false — skip"); return nil end
  return cfg
end

-- Fix (2026-07-07): resolve_sha() wird bei JEDEM do_check() (alle 120s, pro
-- Node) aufgerufen und schlug bei mehreren gleichzeitig laufenden Nodes
-- hinter derselben Server-IP das unauthentifizierte api.github.com-Limit
-- (60 Requests/Stunde/IP) tot — beobachtet: 403 "rate limit exceeded".
-- Die SHA wird nur für Cache-Busting/Konsistenz gebraucht, nicht zwingend
-- fürs Funktionieren (fetch_remote_version()/run_update() haben bereits
-- einen SHA-losen "beta/..."-Fallback). Deshalb: nur noch 1 Versuch statt 3,
-- kein Retry-Sleep mehr, und der Fehlergrund wird geloggt statt
-- stillschweigend verschluckt — so bleibt sichtbar, ob ein Fehlschlag am
-- Rate-Limit lag oder an etwas anderem.
local function resolve_sha()
  if not http or type(http.get) ~= "function" then return nil end
  local body, err = http_get_async(GITHUB_API)
  if body then
    local sha = body:match('"sha"%s*:%s*"(%x+)"')
    if sha then return sha end
    log("SHA-Aufloesung: Antwort ohne 'sha'-Feld (evtl. Rate-Limit-Fehlerseite)")
    return nil
  end
  log("SHA-Aufloesung fehlgeschlagen: " .. tostring(err or "unbekannt") .. " — nutze SHA-losen Fallback")
  return nil
end

local function read_version(path)
  if not fs or not fs.exists(path) then return nil end
  local f = fs.open(path, "r"); if not f then return nil end
  local src = f.readAll(); f.close()
  return tonumber(src:match("manifest_version%s*=%s*(%d+)"))
end

-- Fix (2026-07-07): installer/http.lua's M.download() haengt bei jedem
-- Versuch einen Cache-Buster an ("?xr_cb=..."), aber auto_update.lua rief
-- http_get_async() bisher IMMER mit der nackten URL auf. raw.githubuser
-- content.com cached 5 Minuten (max-age=300) — bei mehreren schnellen
-- Pushes hintereinander (z.B. mehrere bump-Commits in kurzer Zeit) konnte
-- der Auto-Updater so eine veraltete, zwischengespeicherte Version
-- bekommen, obwohl GitHub selbst laengst aktueller war. Jeder Versuch
-- bekommt jetzt einen eigenen, unterschiedlichen Cache-Buster.
local function cache_bust(url, attempt)
  local sep = url:find("?", 1, true) and "&" or "?"
  local t = tostring(os.epoch and os.epoch("utc") or os.time())
  return url .. sep .. "xr_cb=" .. tostring(attempt) .. "_" .. t
end

local function fetch_remote_version(sha)
  local urls = sha and {
    GITHUB_RAW .. sha .. "/xreactor/release.lua",
    GITHUB_RAW .. "beta/xreactor/release.lua",
  } or { GITHUB_RAW .. "beta/xreactor/release.lua" }
  for _, url in ipairs(urls) do
    for attempt = 1, 3 do
      local body, err = http_get_async(cache_bust(url, attempt))
      if body then
        local s = body:sub(1, 200):lower()
        if not s:find("<html", 1, true) and not s:find("<!doctype", 1, true) then
          local v = tonumber(body:match("manifest_version%s*=%s*(%d+)"))
          if v then return v end
        end
      end
      if attempt < 3 then os.sleep(3) end
    end
  end
  return nil
end

local function run_update(sha)
  local urls = sha and {
    GITHUB_RAW .. sha .. "/installer",
    GITHUB_RAW .. "beta/installer",
  } or { GITHUB_RAW .. "beta/installer" }
  -- Fix (2026-07-07): vorher wurde bei einem Fehlschlag nur pauschal
  -- "alle Download-Versuche fehlgeschlagen" geloggt — der tatsächliche
  -- Grund (Timeout, HTTP-Code, leere Antwort, unerwartetes HTML) wurde
  -- verworfen. Jetzt wird jeder Fehlschlag mit Grund geloggt, und der
  -- letzte Fehlergrund wird zurückgegeben statt eines generischen Strings.
  local last_err = "unbekannt"
  local tmp = "/xreactor_auto_update_installer.lua"

  -- Fix (2026-07-07): Diagnose bestätigt "fs.open fehlgeschlagen (Speicher
  -- voll?)" als echten Grund — CC:Tweaked-Computer haben ein internes
  -- Speicherlimit (Server-Config computer.diskSpaceLimit, Standard oft
  -- ~1000 KB). Defensive Bereinigung: ein evtl. verwaister Temp-Rest von
  -- einem durch Absturz/Stromausfall unterbrochenen frueheren Versuch
  -- (vor dem pcall(fs.delete, tmp) je erreicht wurde) wird jetzt VOR jedem
  -- neuen Versuch entfernt, und die tatsaechliche freie/genutzte Speicher-
  -- menge wird bei einem fs.open-Fehlschlag mitgeloggt statt nur vermutet.
  if fs and fs.exists and fs.exists(tmp) then
    pcall(fs.delete, tmp)
    log("verwaiste Temp-Datei " .. tmp .. " vor Update-Versuch entfernt")
  end

  -- Fix (2026-07-07): der manuelle Installer (installer/stage.lua) hat
  -- schon eine reclaim()-Funktion, die vor jedem Schreibvorgang bei
  -- Platzmangel /xreactor_logs, /xreactor_backup_prev und /xreactor_stage
  -- aufraeumt — auto_update.lua nutzte das bisher NIE, sondern schrieb die
  -- Temp-Datei direkt ohne jeden Reclaim-Versuch. Der lokale Log-Puffer
  -- kann bis zu 200 KB einnehmen (core/logger.lua MAX_BYTES) und wurde nie
  -- automatisch vom Auto-Updater entfernt — wahrscheinlicher Hauptgrund
  -- fuer "Speicher voll". Gleiche Logik jetzt hier nachgebaut.
  local function free_space_root()
    if not (fs and type(fs.getFreeSpace) == "function") then return nil end
    local ok, v = pcall(fs.getFreeSpace, "/")
    if not ok then return nil end
    if type(v) == "string" then
      if v:lower() == "unlimited" then return math.huge end
      v = tonumber(v)
    end
    if type(v) == "number" then return v < 0 and math.huge or v end
    return nil
  end

  local function reclaim(needed)
    local free = free_space_root()
    if free and free >= needed then return true end
    local reclaimed = {}
    if fs.exists("/xreactor_logs") then
      pcall(fs.delete, "/xreactor_logs"); reclaimed[#reclaimed+1] = "/xreactor_logs"
    end
    pcall(fs.makeDir, "/xreactor_logs")
    if fs.exists("/xreactor_backup_prev") then
      pcall(fs.delete, "/xreactor_backup_prev"); reclaimed[#reclaimed+1] = "/xreactor_backup_prev"
    end
    if fs.exists("/xreactor_stage") then
      pcall(fs.delete, "/xreactor_stage"); reclaimed[#reclaimed+1] = "/xreactor_stage"
    end
    if #reclaimed > 0 then
      log("Speicher freigeraeumt: " .. table.concat(reclaimed, ", "))
    end
    free = free_space_root()
    return free == nil or free >= needed
  end

  for _, url in ipairs(urls) do
    for attempt = 1, 4 do
      local delays = {2, 5, 10, 20}
      local body, err = http_get_async(cache_bust(url, attempt))
      if body and #body > 100 then
          local s = body:sub(1, 200):lower()
          if s:find("<html", 1, true) or s:find("<!doctype", 1, true) then
            last_err = "unerwartetes HTML (CDN-Fehlerseite) von " .. url
            log("Versuch " .. attempt .. " (" .. url .. "): " .. last_err)
          else
            reclaim(#body + 1024)
            local f = fs.open(tmp, "w")
            if not f then
              local free = "?"
              local ok_fs, v = pcall(free_space_root)
              if ok_fs and v then free = tostring(v) end
              last_err = "fs.open fuer " .. tmp .. " fehlgeschlagen (auch nach reclaim) — freier Speicher: " .. free .. " Bytes, benoetigt: " .. #body .. " Bytes"
              log("Versuch " .. attempt .. " (" .. url .. "): " .. last_err)
            else
              pcall(function() f.write(body) end); pcall(f.close)
              _G.__xreactor_remote_update = true
              -- shell nicht verfügbar in parallel-Coroutine → dofile nutzen
              local ok_run, run_err = pcall(dofile, tmp)
              pcall(fs.delete, tmp)
              if ok_run then log("Update OK — Neustart"); os.sleep(1); os.reboot(); return true end
              last_err = "dofile Fehler: " .. tostring(run_err)
              log("Versuch " .. attempt .. " (" .. url .. "): " .. last_err)
            end
          end
      else
        last_err = (err and tostring(err)) or (body and ("Antwort zu kurz: " .. #body .. " Bytes") or "kein Body")
        log("Versuch " .. attempt .. " (" .. url .. "): " .. last_err)
      end
      if attempt < 4 then os.sleep(delays[attempt] or 20) end
    end
  end
  return false, "alle Download-Versuche fehlgeschlagen — letzter Grund: " .. tostring(last_err)
end

-- Führt einen einzelnen Versions-Check durch.
local function do_check()
  local cfg = arming()
  if not cfg then log("nicht armed — skip"); return end
  if cfg.auto_update ~= true then log("auto_update=false — skip"); return end

  log("Prüfe Version...")
  local sha      = resolve_sha()
  local remote_v = fetch_remote_version(sha)
  local local_v  = read_version(RELEASE_PATH)

  if not remote_v then
    log("Remote-Version nicht abrufbar")
  elseif not local_v then
    log("Lokale Version unbekannt")
  elseif remote_v <= local_v then
    log("Aktuell (v" .. local_v .. ")")
  else
    log("NEU: v" .. local_v .. " -> v" .. remote_v .. " — Update startet")
    local success = false
    for attempt = 1, 3 do
      log("Versuch " .. attempt .. "/3")
      local ok_u, err_u = run_update(sha)
      if ok_u then success = true; break end
      log("Fehlgeschlagen: " .. tostring(err_u))
      if attempt < 3 then os.sleep(5) end
    end
    if not success then
      log("Alle Versuche fehlgeschlagen — Pause 60s")
      os.sleep(60)
    end
  end
end

function M.make_loop(interval_s)
  interval_s = tonumber(interval_s) or 120
  return function()
    log("Loop gestartet (Intervall " .. interval_s .. "s)")
    -- Erster Check nach 30s damit nicht zu lange gewartet wird
    local first = os.startTimer(30)
    repeat local ev, id = os.pullEvent() until ev == "timer" and id == first
    do_check()
    -- Danach regulärer Intervall
    while true do
      local t = os.startTimer(interval_s)
      repeat local ev, id = os.pullEvent() until ev == "timer" and id == t
      do_check()
    end
  end
end

return M
