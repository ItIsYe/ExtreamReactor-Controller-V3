-- core/auto_update.lua
--
-- Periodischer Versions-Check + automatisches Update.
-- Wird vom Node-Bootstrap als optionaler Hintergrundservice gestartet.
--
-- Konfiguration in /xreactor/config/remote_update.lua:
--   return {
--     enabled      = true,   -- Remote-Update muss armed sein
--     auto_update  = true,   -- Auto-Check aktivieren
--     check_interval_s = 300 -- Prüfintervall in Sekunden (default: 300 = 5 min)
--   }

local M = {}

local RELEASE_URL_TEMPLATE = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/release.lua"
local LOCAL_RELEASE_PATH    = "/xreactor/release.lua"
local ARMING_PATH           = "/xreactor/config/remote_update.lua"
local DEFAULT_INTERVAL_S    = 300  -- 5 Minuten

-- Lokale Versionsnummer lesen
local function get_local_version()
  if not fs or not fs.exists(LOCAL_RELEASE_PATH) then return nil end
  local h = fs.open(LOCAL_RELEASE_PATH, "r")
  if not h then return nil end
  local src = h.readAll(); h.close()
  local v = src:match("manifest_version%s*=%s*(%d+)")
  return v and tonumber(v) or nil
end

-- Remote Versionsnummer direkt vom dokumentierten beta-Ref lesen.
local function get_remote_version(log)
  if not http or type(http.get) ~= "function" then return nil end
  local ok, resp = pcall(http.get, RELEASE_URL_TEMPLATE, nil, { timeout = 10 })
  if not ok or not resp then
    log("WARN", "AutoUpdate: release.lua Download fehlgeschlagen")
    return nil
  end
  local ok2, body = pcall(resp.readAll); pcall(resp.close)
  if not ok2 or type(body) ~= "string" then return nil end
  local v = body:match("manifest_version%s*=%s*(%d+)")
  return v and tonumber(v) or nil
end

-- Arming-Config laden
local function load_arming_config()
  if not fs or not fs.exists(ARMING_PATH) then return nil end
  local h = fs.open(ARMING_PATH, "r")
  if not h then return nil end
  local src = h.readAll(); h.close()
  local loader, err = load(src, "=auto_update_arming", "t", {})
  if not loader then return nil end
  local ok, cfg = pcall(loader)
  if not ok or type(cfg) ~= "table" then return nil end
  return cfg
end

-- Einmaliger Versions-Check + Update wenn nötig
function M.check_and_update(log, remote_update_module)
  log = log or function() end
  local cfg = load_arming_config()
  if not cfg or cfg.enabled ~= true then
    log("DEBUG", "AutoUpdate: nicht armed, skip")
    return false, "not armed"
  end
  if cfg.auto_update ~= true then
    log("DEBUG", "AutoUpdate: auto_update=false, skip")
    return false, "disabled"
  end
  local local_v = get_local_version()
  if not local_v then
    log("WARN", "AutoUpdate: lokale Version unbekannt, skip")
    return false, "no local version"
  end
  local remote_v = get_remote_version(log)
  if not remote_v then
    log("WARN", "AutoUpdate: Remote-Version nicht abrufbar, skip")
    return false, "no remote version"
  end
  log("INFO", ("AutoUpdate: lokal=v%d remote=v%d"):format(local_v, remote_v))
  if remote_v <= local_v then
    log("INFO", "AutoUpdate: aktuell, kein Update nötig")
    return false, "up to date"
  end
  -- Neue Version gefunden
  log("WARN", ("AutoUpdate: neue Version v%d → Update starten"):format(remote_v))
  if type(remote_update_module) ~= "table"
     or type(remote_update_module.run) ~= "function" then
    log("ERROR", "AutoUpdate: remote_update Modul nicht verfügbar")
    return false, "no remote_update module"
  end
  local ok, err = remote_update_module.run(log)
  if not ok then
    log("ERROR", "AutoUpdate: Update fehlgeschlagen: " .. tostring(err))
    return false, err
  end
  return true, "updated"
end

-- Dauerschleife: alle check_interval_s Sekunden prüfen.
-- Wird in einem parallelen Thread gestartet.
function M.run_loop(log, remote_update_module, opts)
  opts = opts or {}
  local cfg = load_arming_config() or {}
  local interval = tonumber(cfg.check_interval_s) or DEFAULT_INTERVAL_S
  log = log or function() end
  log("INFO", ("AutoUpdate-Loop gestartet (Intervall %ds)"):format(interval))
  while true do
    -- Warte zuerst — beim Start ist der Installer frisch gelaufen
    local ok_sleep, err_sleep = pcall(function()
      if os and type(os.sleep) == "function" then os.sleep(interval) end
    end)
    if not ok_sleep then return end  -- Thread wurde beendet
    local ok, reason = M.check_and_update(log, remote_update_module)
    if ok then
      -- Update erfolgreich → reboot wurde bereits von remote_update.run ausgelöst
      return
    end
  end
end

return M
