-- nodes/rt/capacity_cache.lua
--
-- Disk-Persistenz für das Capacity-Learning der RT-Node. Speichert/lädt den
-- zuletzt gemessenen max_output-Wert, damit eine Node nach einem Reboot
-- nicht bei 0 anfängt, sondern direkt mit dem zuletzt bekannten Wert
-- startet — die laufende Messung (siehe status_snapshot.lua,
-- update_capacity_learning) aktualisiert ihn danach weiter ganz normal.
--
-- WICHTIG: diese Datei liegt innerhalb von INSTALL_ROOT und wird bei einem
-- Reinstall daher gelöscht — der Installer sichert/stellt sie deshalb
-- separat wieder her (siehe installer_main.lua PRESERVE_ON_REINSTALL, v94).

local M = {}

-- opts: { path = string, turbine_count = number }
function M.save(learning, opts)
  if type(learning) ~= "table" or not learning.ready then return false, "not ready" end
  opts = opts or {}
  local path = opts.path
  if type(path) ~= "string" or path == "" then return false, "no path" end

  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    pcall(fs.makeDir, dir)
  end
  local ok, f = pcall(fs.open, path, "w")
  if not ok or not f then return false, "open failed" end

  local turbine_count = tonumber(opts.turbine_count) or 0
  f.writeLine("-- RT capacity cache - auto-generated, do not edit")
  f.writeLine("return {")
  f.writeLine("  ready = true,")
  f.writeLine(string.format("  max_output = %s,", tostring(learning.max_output or 0)))
  f.writeLine(string.format("  turbine_count = %s,", tostring(turbine_count)))
  f.writeLine(string.format("  reason = %q,", tostring(learning.reason or "LOADED_FROM_CACHE")))
  f.writeLine("}")
  pcall(f.close)
  return true
end

-- opts: { path = string, turbine_count = number, log = function(level, msg) }
function M.load(opts)
  opts = opts or {}
  local path = opts.path
  local log = type(opts.log) == "function" and opts.log or function() end
  if type(path) ~= "string" or path == "" or not fs.exists(path) then return nil end

  local ok, data = pcall(dofile, path)
  if not ok or type(data) ~= "table" or data.ready ~= true
      or type(data.max_output) ~= "number" or data.max_output <= 0 then
    return nil
  end

  -- Hinweis: anders als vorher wird der Cache NICHT mehr bei abweichender
  -- turbine_count gelöscht/verworfen — die laufende Messung passt den Wert
  -- ohnehin automatisch an, sobald sich die Turbinenzahl geändert hat
  -- (mehr Turbinen -> höhere Messung wird automatisch übernommen, siehe
  -- update_capacity_learning "UPDATED"-Fall). Der gecachte Wert ist nur ein
  -- Startpunkt, kein dauerhaft fixierter Lock-Zustand mehr.
  data.reason = data.reason or "LOADED_FROM_CACHE"
  return data
end

return M
