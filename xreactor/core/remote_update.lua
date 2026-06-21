-- core/remote_update.lua
--
-- TEMPORÄRES FEATURE — gedacht für die aktive Entwicklungsphase, in der
-- Nodes häufig neue Versionen brauchen ohne jede einzeln manuell am PC
-- den Installer ausführen zu müssen. Kann später wieder entfernt werden.
--
-- Wird ausgelöst durch:
--   a) REMOTE_UPDATE Command vom Master (über Control-Kanal) — jede Node
--      ruft beim Empfang M.handle_command(opts) auf (siehe unten)
--   b) Redstone-Signal auf "top" des Master-Computers selbst, das den
--      Broadcast an alle Nodes auslöst UND den Master selbst aktualisiert
--      (siehe master/runtime_loop.lua)
--
-- Der Installer läuft non-interaktiv: vorhandene Rolle wird automatisch
-- beibehalten (keine Rückfrage), damit das über Funk ohne Tastatureingabe
-- funktioniert.
--
-- M.handle_command(opts) ist die EINE zentrale Stelle für "ein REMOTE_UPDATE
-- Command kam an, was jetzt?" — vorher war dieselbe Logik (ACK senden, kurz
-- loggen, M.run aufrufen) an 4 verschiedenen Stellen im Code dupliziert
-- (rt/command_handler.lua, support/command_handler.lua, energy/main.lua,
-- master/runtime_loop.lua), jede mit leicht abweichendem Code. Künftige
-- Verhaltensänderungen (z.B. Versions-Check vor dem Update, Bestätigung
-- abwarten) müssen jetzt nur noch hier einmal geändert werden.
--
-- opts:
--   log_prefix (string)   — z.B. "RT", "ENERGY", "SUPPORT" (für Log-Zeilen)
--   utils (table, optional) — falls vorhanden, nutzt utils.log(prefix, msg, level)
--   log_fn (function, optional) — alternativ direkter Log-Callback(level, text)
--   send_ack (function, optional) — wird VOR dem Update-Start aufgerufen,
--     um dem Master sofort zu bestätigen dass das Command angekommen ist
--     (der eigentliche Installer-Lauf braucht Zeit und rebootet danach,
--     ein Status-Antwort-Roundtrip macht zu diesem Zeitpunkt keinen Sinn mehr)

local M = {}

local function make_log(opts)
  if type(opts.log_fn) == "function" then
    return opts.log_fn
  end
  if type(opts.utils) == "table" and type(opts.utils.log) == "function" then
    local prefix = opts.log_prefix or "NODE"
    return function(level, text) opts.utils.log(prefix, text, level) end
  end
  return function() end
end

-- Lädt den Installer von GitHub frisch herunter und führt ihn aus.
function M.run(log_fn)
  local log = type(log_fn) == "function" and log_fn or function() end

  log("INFO", "Remote-Update: lade Installer...")
  if not http or type(http.get) == "nil" then
    log("ERROR", "Remote-Update: http nicht verfuegbar, abgebrochen")
    return false, "no http"
  end

  local url = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer"
  local ok_fetch, response = pcall(http.get, url)
  if not ok_fetch or not response then
    log("ERROR", "Remote-Update: Installer-Download fehlgeschlagen")
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

  -- non-interaktiv: bestehende Rolle automatisch beibehalten/neu installieren
  -- (entspricht Druecken von "j" bei der "Diese Rolle behalten?" Abfrage).
  _G.__xreactor_remote_update = true

  log("INFO", "Remote-Update: starte Installer...")
  -- shell.run() ist nur in einer interaktiven Shell-Umgebung verfügbar.
  -- Diese Funktion läuft typischerweise als Hintergrund-Code (per dofile
  -- geladen), wo die globale shell-API nicht existiert. dofile() ist die
  -- native, shell-unabhängige Alternative dafür.
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

-- Zentraler Einstiegspunkt für alle Node-Typen, wenn ein REMOTE_UPDATE
-- Command vom Master ankommt. Sendet (falls möglich) zuerst ein ACK, loggt
-- den Start, und ruft dann M.run() auf.
function M.handle_command(opts)
  opts = opts or {}
  local log = make_log(opts)
  if type(opts.send_ack) == "function" then
    pcall(opts.send_ack)
  end
  log("WARN", "Remote-Update command received, starting installer...")
  return M.run(log)
end

return M
