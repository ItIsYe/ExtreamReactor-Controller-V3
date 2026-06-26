-- core/remote_update.lua
--
-- Funk-Update bleibt vorhanden, ist aber ab jetzt explizit arming-geschuetzt.
-- Ohne lokale Freigabedatei wird kein Installer geladen und kein Update gestartet.
--
-- Arming-Datei auf jedem Computer:
--   /xreactor/config/remote_update.lua
--
-- Minimal:
--   return { enabled = true }
--
-- Optional enger:
--   return { enabled = true, token = "mein-token" }
--
-- Wenn ein Token gesetzt ist, muss der Command payload.command.token denselben Wert
-- enthalten. Damit bleibt Remote-Update nutzbar, aber ein versehentliches Redstone-
-- Signal oder altes Broadcast-Paket startet nicht mehr sofort den Installer.

local M = {}

local ARMING_CONFIG_PATH = "/xreactor/config/remote_update.lua"

local function make_log(opts)
  opts = opts or {}
  if type(opts.log_fn) == "function" then
    return opts.log_fn
  end
  if type(opts.utils) == "table" and type(opts.utils.log) == "function" then
    local prefix = opts.log_prefix or "NODE"
    return function(level, text) opts.utils.log(prefix, text, level) end
  end
  return function() end
end

local function load_arming_config()
  if not fs or type(fs.exists) ~= "function" or type(fs.open) ~= "function" then
    return nil, "fs unavailable"
  end
  if not fs.exists(ARMING_CONFIG_PATH) then
    return nil, "not armed"
  end
  local handle = fs.open(ARMING_CONFIG_PATH, "r")
  if not handle then return nil, "arming config unreadable" end
  local content = handle.readAll()
  handle.close()
  local loader, err = load(content, "=remote_update_arming", "t", {})
  if not loader then return nil, "arming config parse failed: " .. tostring(err) end
  local ok, result = pcall(loader)
  if not ok then return nil, "arming config failed: " .. tostring(result) end
  if type(result) ~= "table" or result.enabled ~= true then
    return nil, "not armed"
  end
  return result
end

local function command_token(opts)
  local message = opts and opts.message or nil
  local payload = type(message) == "table" and message.payload or nil
  local command = type(payload) == "table" and payload.command or nil
  if type(command) == "table" then return command.token end
  return opts and opts.token or nil
end

function M.is_armed(opts)
  local cfg, reason = load_arming_config()
  if not cfg then return false, reason end
  if cfg.token ~= nil then
    local token = command_token(opts)
    if tostring(token or "") ~= tostring(cfg.token) then
      return false, "token mismatch"
    end
  end
  return true, "armed"
end

-- Hilfsfunktionen fuer robuste Downloads
local INSTALLER_URL_BRANCH = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer"
local INSTALLER_API_URL    = "https://api.github.com/repos/ItIsYe/ExtreamReactor-Controller-V3/branches/beta"
local INSTALLER_REPO       = "ItIsYe/ExtreamReactor-Controller-V3"

local function is_html(body)
  if type(body) ~= "string" then return false end
  local s = body:sub(1, 200):lower()
  return s:find("<html", 1, true) ~= nil or s:find("<!doctype", 1, true) ~= nil
end

local function resolve_installer_sha(log)
  if not http or type(http.get) ~= "function" then return nil end
  local ok, r = pcall(http.get, INSTALLER_API_URL, nil, { timeout = 10 })
  if not ok or not r then
    log("WARN", "Remote-Update: Branch-SHA nicht auflösbar (API timeout)")
    return nil
  end
  local ok2, body = pcall(r.readAll); pcall(r.close)
  if not ok2 or type(body) ~= "string" then return nil end
  local sha = body:match('"sha"%s*:%s*"(%x+)"')
  if sha then
    log("INFO", "Remote-Update: SHA-PIN " .. sha:sub(1, 10))
  end
  return sha
end

local function download_installer(log)
  -- SHA-PIN aufloesen damit CDN-Cache umgangen wird
  local sha = resolve_installer_sha(log)
  local urls = {}
  if sha then
    -- SHA-basierte URL zuerst (Cache-sicher)
    urls[1] = "https://raw.githubusercontent.com/" .. INSTALLER_REPO .. "/" .. sha .. "/installer"
    urls[2] = INSTALLER_URL_BRANCH  -- Fallback
  else
    urls[1] = INSTALLER_URL_BRANCH
  end

  local MAX_RETRIES = 4
  local RETRY_DELAYS = { 2, 5, 10, 20 }  -- exponentiell

  for _, url in ipairs(urls) do
    for attempt = 1, MAX_RETRIES do
      log("INFO", ("Remote-Update: Download Versuch %d/%d url=%s"):format(
        attempt, MAX_RETRIES, url:sub(1, 60)))
      local ok, r = pcall(http.get, url, nil, { timeout = 20 })
      if ok and r then
        local ok2, body = pcall(r.readAll); pcall(r.close)
        if ok2 and type(body) == "string" and #body > 100 then
          if is_html(body) then
            log("WARN", ("Remote-Update: HTML-Antwort (CDN-Fehler), Versuch %d"):format(attempt))
          else
            log("INFO", ("Remote-Update: Download OK (%d bytes)"):format(#body))
            return body, url
          end
        else
          log("WARN", ("Remote-Update: leerer/ungültiger Body, Versuch %d"):format(attempt))
        end
      else
        local err = type(r) == "string" and r or "timeout/network"
        log("WARN", ("Remote-Update: HTTP-Fehler Versuch %d: %s"):format(attempt, err))
      end
      -- Warte vor nächstem Versuch (ausser nach letztem)
      if attempt < MAX_RETRIES then
        local delay = RETRY_DELAYS[attempt] or 20
        log("INFO", ("Remote-Update: warte %ds..."):format(delay))
        if os and type(os.sleep) == "function" then os.sleep(delay) end
      end
    end
    -- URL fehlgeschlagen → nächste URL versuchen
    if #urls > 1 then
      log("WARN", "Remote-Update: erste URL fehlgeschlagen, versuche Fallback-URL...")
    end
  end
  return nil, "alle Download-Versuche fehlgeschlagen"
end

-- Lädt den Installer von GitHub frisch herunter und führt ihn aus.
-- Immer von GitHub (kein lokaler Installer-Cache) damit die neuste
-- Version des Installers selbst genutzt wird.
function M.run(log_fn, opts)
  opts = opts or {}
  local log = type(log_fn) == "function" and log_fn or function() end

  local armed, arm_reason = M.is_armed(opts)
  if not armed then
    log("WARN", "Remote-Update blocked: " .. tostring(arm_reason) ..
        " (create " .. ARMING_CONFIG_PATH .. " to arm)")
    return false, arm_reason or "not armed"
  end

  if not http or type(http.get) ~= "function" then
    log("ERROR", "Remote-Update: http nicht verfuegbar")
    return false, "no http"
  end

  log("INFO", "Remote-Update: arming OK, lade Installer von GitHub...")

  local body, url_or_err = download_installer(log)
  if not body then
    log("ERROR", "Remote-Update: " .. tostring(url_or_err))
    return false, url_or_err
  end

  -- Auf Disk schreiben
  local path = "/xreactor_remote_update_installer.lua"
  local ok_w, h_or_err = pcall(fs.open, path, "w")
  if not ok_w or not h_or_err then
    log("ERROR", "Remote-Update: Schreiben fehlgeschlagen: " .. tostring(h_or_err))
    return false, "write failed"
  end
  local h = h_or_err
  local ok_write = pcall(h.write, h, body)
  pcall(h.close, h)
  if not ok_write then
    log("ERROR", "Remote-Update: Datei-Write fehlgeschlagen")
    return false, "write error"
  end

  _G.__xreactor_remote_update = true
  log("INFO", "Remote-Update: starte Installer...")

  local ok_run, run_err
  if type(shell) == "table" and type(shell.run) == "function" then
    ok_run, run_err = pcall(shell.run, path)
  else
    ok_run, run_err = pcall(dofile, path)
  end

  -- Aufräumen
  pcall(fs.delete, path)

  if not ok_run then
    log("ERROR", "Remote-Update: Installer-Lauf fehlgeschlagen: " .. tostring(run_err))
    return false, tostring(run_err)
  end

  log("INFO", "Remote-Update: Installer fertig, rebooting...")
  if os and type(os.sleep) == "function" then os.sleep(1) end
  if os and type(os.reboot) == "function" then os.reboot() end
  return true
end

function M.handle_command(opts)
  opts = opts or {}
  local log = make_log(opts)
  local armed, arm_reason = M.is_armed(opts)
  if not armed then
    log("WARN", "Remote-Update command blocked: " .. tostring(arm_reason) .. " (not armed)")
    return false, arm_reason or "not armed"
  end
  if type(opts.send_ack) == "function" then
    pcall(opts.send_ack)
  end
  log("WARN", "Remote-Update command accepted, starting installer...")
  -- Versions-Check: remote release.lua holen und mit lokaler vergleichen.
-- SHA-PIN + Retries + HTML-Check — gleiche Robustheit wie M.run.
-- Gibt nil zurück wenn nicht erreichbar oder gleich, sonst remote_version.
function M.check_version(log)
  log = log or function() end
  if not http or type(http.get) ~= "function" then return nil end

  -- SHA aufloesen (3 Versuche, 3s Pause)
  local sha = nil
  for attempt = 1, 3 do
    local ok, r = pcall(http.get, INSTALLER_API_URL, nil, { timeout = 10 })
    if ok and r then
      local ok2, body = pcall(r.readAll); pcall(r.close)
      if ok2 and type(body) == "string" then
        sha = body:match('"sha"%s*:%s*"(%x+)"')
        if sha then break end
      end
    end
    if attempt < 3 then
      if os and type(os.sleep) == "function" then os.sleep(3) end
    end
  end

  -- release.lua URLs: SHA zuerst, dann Branch als Fallback
  local urls = {}
  if sha then
    urls[1] = "https://raw.githubusercontent.com/" .. INSTALLER_REPO .. "/" .. sha .. "/xreactor/release.lua"
    urls[2] = "https://raw.githubusercontent.com/" .. INSTALLER_REPO .. "/beta/xreactor/release.lua"
  else
    urls[1] = "https://raw.githubusercontent.com/" .. INSTALLER_REPO .. "/beta/xreactor/release.lua"
  end

  local remote_v = nil
  for _, url in ipairs(urls) do
    for attempt = 1, 3 do
      local ok, r = pcall(http.get, url, nil, { timeout = 10 })
      if ok and r then
        local ok2, body = pcall(r.readAll); pcall(r.close)
        if ok2 and type(body) == "string" and #body > 10 then
          if is_html(body) then
            log("WARN", ("AutoUpdate: HTML-Antwort Versuch %d"):format(attempt))
          else
            remote_v = tonumber(body:match("manifest_version%s*=%s*(%d+)"))
            if remote_v then break end
          end
        end
      end
      if attempt < 3 then
        if os and type(os.sleep) == "function" then os.sleep(3) end
      end
    end
    if remote_v then break end
  end

  if not remote_v then
    log("WARN", "AutoUpdate: Remote-Version nicht abrufbar")
    return nil
  end

  -- Lokale Version
  local local_v = nil
  if fs and fs.exists("/xreactor/release.lua") then
    local ok_h, h = pcall(fs.open, "/xreactor/release.lua", "r")
    if ok_h and h then
      local src = h.readAll(); h.close()
      local_v = tonumber(src:match("manifest_version%s*=%s*(%d+)"))
    end
  end
  if not local_v then
    log("WARN", "AutoUpdate: lokale Version unbekannt")
    return nil
  end

  log("INFO", ("AutoUpdate: lokal=v%d remote=v%d"):format(local_v, remote_v))
  if remote_v <= local_v then return nil end
  return remote_v
end

-- Startet einen periodischen Versions-Check als parallelen os.timer-Loop.
-- check_interval_s: Sekunden zwischen Checks (default 300 = 5 min).
-- Wird vom Node-Main über parallel.waitForAny() oder os.timer eingehängt.
-- Gibt eine Funktion zurück die in parallel.waitForAny() läuft.
function M.auto_check_loop(log, check_interval_s)
  log = log or function() end
  check_interval_s = tonumber(check_interval_s) or 300
  return function()
    while true do
      -- Warte zuerst — nach einem frischen Install ist Update unnötig
      local timer_id = os.startTimer and os.startTimer(check_interval_s) or nil
      if timer_id then
        -- Warte auf den Timer-Event (ohne den Rest des Systems zu blockieren)
        repeat
          local ev, id = os.pullEvent("timer")
        until id == timer_id
      else
        os.sleep(check_interval_s)
      end
      -- Armed?
      local cfg_armed, _ = M.is_armed()
      if not cfg_armed then
        log("DEBUG", "AutoUpdate: nicht armed, skip")
      else
        -- Arming-Config auf auto_update prüfen
        local h2 = fs and fs.exists(ARMING_CONFIG_PATH) and fs.open(ARMING_CONFIG_PATH, "r")
        local auto_enabled = false
        if h2 then
          local src = h2.readAll(); h2.close()
          local loader = load(src, "=arm", "t", {})
          if loader then
            local ok2, cfg2 = pcall(loader)
            if ok2 and type(cfg2) == "table" then
              auto_enabled = cfg2.auto_update == true
            end
          end
        end
        if not auto_enabled then
          log("DEBUG", "AutoUpdate: auto_update nicht aktiviert")
        else
          local new_v = M.check_version(log)
          if new_v then
            log("WARN", ("AutoUpdate: neue Version v%d — starte Update"):format(new_v))
            -- 3 Versuche
            local success = false
            for attempt = 1, 3 do
              log("INFO", ("AutoUpdate: Versuch %d/3"):format(attempt))
              local ok_run, err_run = M.run(log)
              if ok_run then success = true; break end
              log("WARN", ("AutoUpdate: Versuch %d fehlgeschlagen: %s"):format(attempt, tostring(err_run)))
              if attempt < 3 then os.sleep(5) end
            end
            if not success then
              log("ERROR", ("AutoUpdate: alle 3 Versuche fehlgeschlagen — naechster Check in %ds"):format(check_interval_s))
              -- Extra-Wartezeit nach fehlgeschlagenem Update (kein Retry-Spam)
              if os and type(os.sleep) == "function" then os.sleep(60) end
            else
              return  -- reboot wurde ausgelöst
            end
          end
        end
      end
    end
  end
end

return M.run(log, opts)
end

return M
