-- services/auto_update_service.lua
-- Wrapper um installer/auto_update.lua für alle Nodes.
-- Lädt das Modul lazy damit Nodes auch ohne installer/ starten können.

local M = {}

local AUTO_UPDATE_PATH = "/xreactor/installer/auto_update.lua"
local ARMING_PATH      = "/xreactor/config/remote_update.lua"

-- Erstellt einen Auto-Update Loop für parallel.waitForAny().
-- opts:
--   interval_s  — Sekunden zwischen Checks (default aus Config oder 120)
--   log         — function(msg) optional (nur print wenn nil)
-- Gibt nil zurück wenn installer/auto_update.lua nicht verfügbar.
function M.make_loop(opts)
  opts = opts or {}
  local log = opts.log or function(msg) pcall(print, "[AUTO] " .. tostring(msg)) end

  if not fs or not fs.exists(AUTO_UPDATE_PATH) then
    log("installer/auto_update.lua fehlt — kein Auto-Update")
    return nil
  end

  local ok, auto_mod = pcall(dofile, AUTO_UPDATE_PATH)
  if not ok or type(auto_mod) ~= "table" or type(auto_mod.make_loop) ~= "function" then
    log("auto_update.lua Ladefehler: " .. tostring(auto_mod))
    return nil
  end

  -- Intervall aus Arming-Config lesen
  local interval_s = tonumber(opts.interval_s) or 120
  if fs.exists(ARMING_PATH) then
    local f = fs.open(ARMING_PATH, "r")
    if f then
      local src = f.readAll(); f.close()
      local loader = load(src, "=arm", "t", {})
      if loader then
        local ok2, cfg = pcall(loader)
        if ok2 and type(cfg) == "table" then
          interval_s = tonumber(cfg.check_interval_s) or interval_s
        end
      end
    end
  end

  log("Auto-Update Loop bereit (Intervall " .. interval_s .. "s)")
  return auto_mod.make_loop(interval_s)
end

return M
