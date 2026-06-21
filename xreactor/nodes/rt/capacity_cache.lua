-- nodes/rt/capacity_cache.lua
--
-- Disk-Persistenz für das Capacity-Learning der RT-Node. Ausgelagert aus
-- main.lua (Modularisierung "Punkt 1", Gruppe C — risikoarmer, klar
-- abgegrenzter Teil ohne enge Verflechtung mit Reaktor-/Turbinen-Regelung).
--
-- Schreibt/liest eine generierte Lua-Datei unter CONFIG.CAPACITY_CACHE_PATH
-- (Standard: /xreactor/config/capacity_cache.lua), die den zuletzt
-- gelockten max_output-Wert enthält, damit eine Node nach einem Reboot
-- nicht jedes Mal das komplette Capacity-Learning neu durchlaufen muss.
--
-- WICHTIG: diese Datei liegt innerhalb von INSTALL_ROOT und wird bei einem
-- Reinstall daher gelöscht — der Installer sichert/stellt sie deshalb
-- separat wieder her (siehe installer_main.lua PRESERVE_ON_REINSTALL, v94).

local M = {}

-- opts: { path = string, turbine_count = number }
function M.save(learning, opts)
  if type(learning) ~= "table" or not learning.locked then return false, "not locked" end
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
  f.writeLine("  locked = true,")
  f.writeLine(string.format("  max_output = %s,", tostring(learning.max_output or 0)))
  f.writeLine(string.format("  stable_samples = %s,", tostring(learning.stable_samples or 0)))
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
  if not ok or type(data) ~= "table" or data.locked ~= true
      or type(data.max_output) ~= "number" or data.max_output <= 0 then
    return nil
  end

  -- Invalidate if turbine count changed since the cache was written.
  -- A different turbine count means a different max_output; re-learning
  -- is needed.
  local current_count = tonumber(opts.turbine_count) or 0
  if type(data.turbine_count) == "number" and data.turbine_count ~= current_count then
    log("WARN", string.format(
      "Capacity cache invalidated: turbine_count changed %d->%d, re-learning required",
      data.turbine_count, current_count))
    pcall(fs.delete, path)
    return nil
  end

  data.reason = data.reason or "LOADED_FROM_CACHE"
  return data
end

return M
