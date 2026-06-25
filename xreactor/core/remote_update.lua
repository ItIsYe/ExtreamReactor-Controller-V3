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

-- Lädt den Installer von GitHub frisch herunter und führt ihn aus.
function M.run(log_fn, opts)
  opts = opts or {}
  local log = type(log_fn) == "function" and log_fn or function() end

  local armed, arm_reason = M.is_armed(opts)
  if not armed then
    log("WARN", "Remote-Update blocked: " .. tostring(arm_reason) .. " (create " .. ARMING_CONFIG_PATH .. " to arm)")
    return false, arm_reason or "not armed"
  end

  log("INFO", "Remote-Update: arming OK, lade Installer...")
  if not http or type(http.get) == "nil" then
    log("ERROR", "Remote-Update: http nicht verfuegbar, abgebrochen")
    return false, "no http"
  end

  local url = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer"
  local ok_fetch, response = pcall(http.get, url, nil, { timeout = 15 })
  if not ok_fetch or not response then
    log("ERROR", "Remote-Update: Installer-Download fehlgeschlagen (timeout oder Netzwerkfehler)")
    return false, "download failed"
  end
  local body = response.readAll()
  pcall(response.close)
  if type(body) ~= "string" or #body == 0 then
    log("ERROR", "Remote-Update: leerer Installer-Inhalt")
    return false, "empty body"
  end

  local path = "/xreactor_remote_update_installer.lua"
  local h = fs.open(path, "w")
  if not h then
    log("ERROR", "Remote-Update: konnte Installer nicht auf Disk schreiben")
    return false, "write failed"
  end
  h.write(body)
  h.close()

  _G.__xreactor_remote_update = true

  log("INFO", "Remote-Update: starte Installer...")
  local ok_run, err
  if type(shell) == "table" and type(shell.run) == "function" then
    ok_run, err = pcall(function() shell.run(path) end)
  else
    ok_run, err = pcall(function() dofile(path) end)
  end
  if not ok_run then
    log("ERROR", "Remote-Update: Installer-Lauf fehlgeschlagen: " .. tostring(err))
    return false, tostring(err)
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
  return M.run(log, opts)
end

return M
