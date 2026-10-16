-- nodes/log_collector/ampel_status.lua
--
-- Farbe fuer die optionale Ampel (optional/ampel.lua) am LOG-Collector,
-- Regeln vom Betreiber freigegeben (2026-10-15) -- die erste zutreffende
-- gilt:
--   rot    (EMERGENCY) keine beschreibbare Disk: Logs gehen verloren
--   orange (WARNING)   es gab einen Schreibfehler (stats.last_error)
--   gelb   (LIMITED)   Loggen pausiert
--   grau   (muted)     noch keine Meldung angekommen
--   gruen  (OK)        laeuft
--
-- Eigene Datei statt in main.lua: das ist ein Startskript mit Seiten-
-- effekten und laesst sich nicht per require() pruefen.

local M = {}

function M.status(stats)
  local s = type(stats) == "table" and stats or {}
  if type(s.disks) ~= "table" or #s.disks == 0 then return "EMERGENCY" end
  if s.last_error ~= nil then return "WARNING" end
  if s.paused == true then return "LIMITED" end
  if (tonumber(s.received) or 0) == 0 then return "muted" end
  return "OK"
end

return M
