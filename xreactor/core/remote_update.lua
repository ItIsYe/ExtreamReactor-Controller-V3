-- core/remote_update.lua
--
-- TEMPORÄRES FEATURE — gedacht für die aktive Entwicklungsphase, in der
-- Nodes häufig neue Versionen brauchen ohne jede einzeln manuell am PC
-- den Installer ausführen zu müssen. Kann später wieder entfernt werden.
--
-- Führt den XReactor-Installer auf dieser Node aus und rebooted danach.
-- Wird ausgelöst durch:
--   a) REMOTE_UPDATE Command vom Master (über Control-Kanal)
--   b) Redstone-Signal auf "top" des Master-Computers selbst
--      (siehe master/runtime_loop.lua)
--
-- Der Installer läuft non-interaktiv: vorhandene Rolle wird automatisch
-- beibehalten (keine Rückfrage), damit das über Funk ohne Tastatureingabe
-- funktioniert.

local M = {}

-- Lädt den Installer von GitHub frisch herunter und führt ihn aus.
-- non_interactive=true unterdrückt die "Rolle behalten? [j/n]" Abfrage.
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
  -- Fix: shell.run() ist nur in einer interaktiven Shell-Umgebung verfügbar.
  -- Diese Funktion läuft als Hintergrund-Code (per dofile geladen), wo
  -- die globale shell-API nicht existiert ("attempt to index global 'shell'").
  -- dofile() ist die native, shell-unabhängige Alternative dafür.
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

return M
