-- core/update_handshake.lua
--
-- Rollenübergreifender Update-Handshake (INSTALL-P0.2, siehe docs/CODING_AI_
-- OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitt 4). start.lua startet die
-- Rollen-Hauptschleife und den Auto-Update-Loop als zwei Coroutinen unter
-- parallel.waitForAll(). Beide teilen sich EIN Handshake-Objekt (dieses
-- Modul, instanziiert per M.new()) ueber einen globalen Wert
-- (_G.__xreactor_update_handshake), damit der Auto-Updater eine Aktualisierung
-- anfordern kann, OHNE die Rollen-Coroutine gewaltsam zu unterbrechen: die
-- Rolle prueft den Handshake-Status selbst an einer sicheren Stelle in ihrer
-- eigenen Hauptschleife, faehrt Aktoren kontrolliert in einen sicheren
-- Zustand, meldet das zurueck und beendet sich dann selbst -- erst danach
-- faehrt der Installer fort.
--
-- Zustandsfolge: UPDATE_REQUESTED -> QUIESCE_REQUESTED -> SAFE_OUTPUTS_APPLIED
-- -> RUNTIME_STOPPED (die verbleibenden Stationen INSTALLING/VERIFIED/
-- COMMITTED/REBOOT aus dem Audit-Vorschlag sind bereits durch das
-- Installationsjournal, installer/journal.lua, siehe Abschnitt 3, abgedeckt).

local M = {}

M.STATE = {
  IDLE                  = "IDLE",
  UPDATE_REQUESTED      = "UPDATE_REQUESTED",
  QUIESCE_REQUESTED     = "QUIESCE_REQUESTED",
  SAFE_OUTPUTS_APPLIED  = "SAFE_OUTPUTS_APPLIED",
  RUNTIME_STOPPED       = "RUNTIME_STOPPED",
}

function M.new()
  return { state = M.STATE.IDLE, requested_at = nil }
end

-- Vom Auto-Update-Loop aufgerufen, sobald ein Update tatsaechlich installiert
-- werden soll (nicht schon bei jedem Versions-Check).
function M.request_quiesce(handshake)
  handshake.state = M.STATE.UPDATE_REQUESTED
  handshake.state = M.STATE.QUIESCE_REQUESTED
  handshake.requested_at = os.epoch("utc")
end

function M.is_quiesce_requested(handshake)
  return handshake ~= nil and handshake.state == M.STATE.QUIESCE_REQUESTED
end

-- Von der Rolle aufgerufen, NACHDEM sie ihre Aktoren nachweislich in einen
-- sicheren Zustand gefahren hat (z.B. Ventil zu, Foerderung gestoppt,
-- laufende Transaktion abgebrochen).
function M.mark_safe_outputs_applied(handshake)
  if handshake and handshake.state == M.STATE.QUIESCE_REQUESTED then
    handshake.state = M.STATE.SAFE_OUTPUTS_APPLIED
  end
end

-- Von der Rolle aufgerufen unmittelbar bevor sie ihre Hauptschleife
-- tatsaechlich verlaesst (danach darf keine weitere Aktorsteuerung mehr
-- passieren).
function M.mark_runtime_stopped(handshake)
  if handshake then handshake.state = M.STATE.RUNTIME_STOPPED end
end

function M.is_runtime_stopped(handshake)
  return handshake ~= nil and handshake.state == M.STATE.RUNTIME_STOPPED
end

-- Vom Auto-Update-Loop aufgerufen: wartet (per os.sleep, gibt also die
-- Kontrolle an die andere Coroutine ab) bis RUNTIME_STOPPED erreicht ist
-- oder das Timeout ablaeuft. Liefert false bei Timeout -- der Aufrufer MUSS
-- in diesem Fall den Installationsversuch abbrechen und es spaeter erneut
-- versuchen, NIEMALS ueber eine nicht bestaetigte Quiesce hinweg installieren.
function M.wait_for_runtime_stopped(handshake, timeout_s)
  if not handshake then return true end
  local deadline = os.epoch("utc") + (tonumber(timeout_s) or 20) * 1000
  while handshake.state ~= M.STATE.RUNTIME_STOPPED do
    if os.epoch("utc") >= deadline then return false end
    os.sleep(0.5)
  end
  return true
end

function M.reset(handshake)
  if handshake then
    handshake.state = M.STATE.IDLE
    handshake.requested_at = nil
  end
end

return M
