-- installer/stage.lua
-- Dateien herunterladen und schreiben. Atomic write, Speicher-Check.

local M = {}
local WRITE_BUFFER = 1024

local function free_space()
  if not fs.getFreeSpace then return nil end
  local ok, v = pcall(fs.getFreeSpace, "/")
  if not ok then return nil end
  if type(v) == "string" then
    if v:lower() == "unlimited" then return math.huge end
    v = tonumber(v)
  end
  if type(v) == "number" then return v < 0 and math.huge or v end
  return nil
end

-- Fix (2026-07-16): CRITICAL. INSTALL/LOG-P0 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 16).
-- "/xreactor_logs" wurde hier bisher unconditional rekursiv geloescht,
-- sobald waehrend einer Installation zu wenig freier Speicher uebrig war
-- -- das ist aber KEIN installer-eigenes Zwischenverzeichnis, sondern der
-- tatsaechliche lokale Log-Speicherort (core/logger.lua's DEFAULT_LOG_DIR,
-- genutzt von jeder Rolle als lokaler Fallback bzw. von einer LOG_
-- COLLECTOR-Rolle auf demselben Computer). Ein Platzmangel WAEHREND einer
-- Installation durfte niemals als Erlaubnis gelten, vorhandene Logs zu
-- vernichten. Jetzt werden nur noch echte, installer-eigene, jederzeit
-- regenerierbare Zwischenverzeichnisse entfernt; reicht das nicht, gibt
-- M.write() (und damit letztlich M.install()) einen klaren Fehler zurueck
-- und die Installation bricht kontrolliert ab, statt Nutzerdaten zu
-- opfern.
local function reclaim(needed)
  local free = free_space()
  if free and free >= needed then return true end
  if fs.exists("/xreactor_backup_prev") then pcall(fs.delete, "/xreactor_backup_prev") end
  if fs.exists("/xreactor_stage")       then pcall(fs.delete, "/xreactor_stage") end
  free = free_space()
  return free == nil or free >= needed
end

function M.write(path, content)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
  if not reclaim(#content + WRITE_BUFFER) then
    return false, "not enough space for " .. path
  end
  local tmp = path .. ".xr_tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "open failed: " .. tmp end
  local write_ok, write_err = pcall(function() f.write(content) end)
  pcall(f.close)
  if not write_ok then pcall(fs.delete, tmp); return false, tostring(write_err) end

  -- Fix (2026-07-07): CRITICAL. Vorher wurde die Zieldatei ERST geloescht
  -- und ERST DANACH die neue Datei an ihre Stelle bewegt — dazwischen
  -- existierte "path" fuer einen kurzen Moment ueberhaupt nicht. Ein
  -- Absturz/Neustart/Stromausfall genau in diesem Fenster (bei
  -- "/startup.lua" beobachtet: Computer bootete danach zu "No such
  -- program", weil die Startdatei schlicht fehlte) hinterliess eine
  -- fehlende Datei ohne jede Moeglichkeit zur Wiederherstellung. Jetzt:
  -- die alte Datei wird zu einem Backup-Namen VERSCHOBEN statt geloescht
  -- (die Zieldatei existiert also durchgehend, entweder als alte oder als
  -- neue Version), das eigentliche Ersetzen ist nur noch der finale Move-
  -- Schritt, und bei einem Fehlschlag wird das Backup zurueckgeschoben.
  -- Fix (2026-07-17): CRITICAL. INSTALL-P0.3 aus
  -- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 5). Wenn
  -- der Backup-Move fehlschlug (z.B. kein Platz), wurde die alte Datei
  -- bisher als "letzter Ausweg" trotzdem geloescht und die Funktion lief
  -- weiter, so als waere alles in Ordnung — schlug danach auch noch der
  -- finale tmp->path Move fehl, war die alte Datei unwiderruflich weg UND
  -- kein Backup vorhanden, aus dem "path" haette zurueckgeholt werden
  -- koennen. Jetzt wird die alte Datei NUR geloescht, wenn sie tatsaechlich
  -- am Backup-Pfad wiederzufinden ist (per fs.exists verifiziert, nicht nur
  -- am pcall-Erfolg von fs.move) -- schlaegt das Backup fehl, bricht
  -- M.write() sofort mit klarem Fehler ab, die alte Datei bleibt an ihrem
  -- Platz unangetastet.
  local backup = path .. ".xr_prev"
  local had_old = fs.exists(path)
  if had_old then
    if fs.exists(backup) then
      pcall(fs.delete, backup)
      if fs.exists(backup) then
        pcall(fs.delete, tmp)
        return false, "could not clear stale backup: " .. backup
      end
    end
    pcall(fs.move, path, backup)
    if not fs.exists(backup) then
      pcall(fs.delete, tmp)
      return false, "backup move failed: " .. path .. " -> " .. backup
    end
  end

  local ok2, mv_err = pcall(fs.move, tmp, path)
  if not ok2 or not fs.exists(path) then
    pcall(fs.delete, tmp)
    -- Neue Datei konnte nicht an ihren Platz — altes Backup zurueckholen,
    -- damit "path" nicht dauerhaft fehlt.
    if had_old and fs.exists(backup) and not fs.exists(path) then
      pcall(fs.move, backup, path)
    end
    return false, "move failed: " .. tostring(mv_err)
  end
  if had_old and fs.exists(backup) then pcall(fs.delete, backup) end
  return true
end

function M.read(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local c = f.readAll(); f.close(); return c
end

-- Fix (2026-07-16): CRITICAL. INSTALL-P0 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 15).
-- manifest.lua enthaelt fuer jede Datei einen CRC32-Hash, aber diese
-- Funktion pruefte bisher nur Existenz, Lesbarkeit, Groesse und (bei
-- .lua-Dateien) Syntax -- eine Datei mit korrekter Groesse und gueltiger
-- Syntax, aber veraendertem Inhalt (z.B. durch einen stillen
-- Bit-/Uebertragungsfehler, der die Byteanzahl zufaellig unveraendert
-- liess) wurde akzeptiert. "crc32_fn" wird optional vom Aufrufer
-- durchgereicht (installer/init.lua uebergibt manifest.lua's bereits
-- vorhandene M.crc32) -- kein neuer dofile()/require() hier, um
-- stage.lua nicht von manifest.lua abhaengig zu machen.
function M.verify(path, entry, crc32_fn)
  if not fs.exists(path) then return false, "missing: " .. path end
  local content = M.read(path)
  if not content then return false, "unreadable: " .. path end
  if entry and entry.size_bytes and #content ~= entry.size_bytes then
    return false, string.format("size mismatch %s: got %d expected %d",
      path, #content, entry.size_bytes)
  end
  if entry and entry.hash and entry.hash ~= "" and type(crc32_fn) == "function" then
    local actual = crc32_fn(content)
    if actual:lower() ~= tostring(entry.hash):lower() then
      return false, string.format("hash mismatch %s: got %s expected %s",
        path, actual, entry.hash)
    end
  end
  if path:sub(-4) == ".lua" then
    local loader, lerr = load(content, "=" .. path, "t", {})
    if not loader then return false, "lua syntax: " .. path .. ": " .. tostring(lerr) end
  end
  return true
end

-- Fix (2026-07-10): GitHub's raw.githubusercontent.com kann direkt nach
-- einem frischen Push kurzzeitig noch alten Inhalt an manche Edge-Server
-- ausliefern (Origin-seitige Propagationsverzoegerung, nicht durch
-- Cache-Busting behebbar, da das nur lokales/Proxy-Caching umgeht). Bei
-- einem Size/Hash-Mismatch direkt nach dem Download wird jetzt mit einer
-- kurzen Pause automatisch neu geladen (frischer Cache-Buster-Zeitstempel
-- bei jedem Versuch durch http_mod.download_file()), statt die gesamte
-- Installation sofort abzubrechen. Nur fuer echte Downloads relevant
-- (item.content vorab bereitgestellte Inhalte wuerden bei einem
-- Mismatch nicht durch Neu-Download geloest, das waere ein echter Bug).
local VERIFY_MAX_ATTEMPTS = 4
local VERIFY_RETRY_DELAY_S = 2

function M.install(files, install_root, http_mod, ref, progress_fn, crc32_fn)
  local total = #files
  for i, item in ipairs(files) do
    local rel   = item.path
    local entry = item.entry or {}
    local dest  = install_root .. "/" .. rel
    local last_err

    if item.content then
      -- Vorab bereitgestellter Inhalt (kein Netzwerk-Download) -- kein
      -- Retry sinnvoll, ein Mismatch hier ist ein echter Fehler.
      local ok, werr = M.write(dest, item.content)
      if not ok then return false, werr end
      local ok2, verr = M.verify(dest, entry, crc32_fn)
      if not ok2 then return false, verr end
    else
      local success = false
      if progress_fn then progress_fn(i - 1, total, rel .. " (Download startet...)") end
      for attempt = 1, VERIFY_MAX_ATTEMPTS do
        local body, err = http_mod.download_file(rel, ref)
        if not body then
          last_err = "download failed: " .. rel .. " — " .. tostring(err)
        elseif http_mod.is_html(body) then
          last_err = "unexpected HTML for: " .. rel
        else
          local ok, werr = M.write(dest, body)
          if not ok then
            last_err = werr
          else
            local ok2, verr = M.verify(dest, entry, crc32_fn)
            if ok2 then
              success = true
              break
            end
            last_err = verr
          end
        end
        if attempt < VERIFY_MAX_ATTEMPTS then
          if progress_fn then
            progress_fn(i, total, rel .. " (Versuch " .. attempt .. " fehlgeschlagen, erneuter Versuch...)")
          end
          os.sleep(VERIFY_RETRY_DELAY_S)
        end
      end
      if not success then return false, last_err end
    end

    if progress_fn then progress_fn(i, total, rel) end
  end
  return true
end

return M
