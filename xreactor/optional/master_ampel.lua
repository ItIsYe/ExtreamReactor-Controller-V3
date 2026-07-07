-- xreactor/optional/master_ampel.lua
--
-- Optionale Peripherie: MASTER-Gesamtampel.
--
-- Zweck: eine zentrale 1x3-Ampel am MASTER, die NICHT den Zustand eines
-- einzelnen Nodes zeigt (das macht optional/ampel.lua auf RT/ENERGY),
-- sondern den Gesamtzustand der kompletten Anlage — eine einzige Farbe,
-- die alle Nodes/Alerts zusammenfasst.
--
-- Prioritaet der Zustaende (hoechste zuerst — die erste zutreffende
-- Bedingung gewinnt):
--   1. GRAU   — Anlage aus / RT-Global-Hold aktiv / kein Auftrag
--               (bewusst hoechste Prioritaet: ein absichtlich abgeschaltetes
--               System ist kein Fehlerzustand und soll nicht rot blinken)
--   2. ROT    — mindestens ein CRITICAL-Alert aktiv, ODER ein RT-Node im
--               SAFE/EMERGENCY-Zustand, ODER eine als kritisch markierte
--               Node ist offline
--   3. ORANGE — mindestens ein WARN-Alert aktiv (deckt u.a. die
--               RT_NO_REDUNDANCY-Warnung und Energy-Fuellstand-Warnungen ab)
--   4. GELB   — mindestens ein Node lernt gerade Kapazitaet, oder eine
--               leichte, nicht-kritische Abweichung liegt vor
--   5. GRUEN  — alles normal
--
-- Nutzt dieselbe Monitor-Erkennung/-Rendering-Basis wie optional/ampel.lua
-- (1x3, auto-detected, pcall-isoliert), aber als eigenstaendiges Modul, da
-- die Statuslogik hier komplett anders ist (Gesamtanlage statt Einzelnode)
-- und am MASTER laeuft statt an einzelnen Nodes.

local M = {}

-- Fix (2026-07-06): CRITICAL, derselbe Bug wie in optional/ampel.lua —
-- rohe RGB-Hex-Werte statt echter colors.xxx Bitmask-Konstanten. mon.
-- setBackgroundColor() akzeptiert nur Zweierpotenzen aus der colors-API;
-- ein ungueltiger Wert wirft einen Fehler, der hier durch pcall()
-- verschluckt wurde — Bildschirm blieb dauerhaft schwarz.
local COLORS = {
  green  = colors.green,
  yellow = colors.yellow,
  orange = colors.orange,
  red    = colors.red,
  gray   = colors.gray,
}

local cache = { name = nil, last_color = nil }

local function find_ampel_monitor()
  if not peripheral or type(peripheral.getNames) ~= "function" then return nil end
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return nil end
  for _, name in ipairs(names) do
    local ok_t, ptype = pcall(peripheral.getType, name)
    if ok_t and tostring(ptype):find("monitor", 1, true) then
      local ok_w, mon = pcall(peripheral.wrap, name)
      if ok_w and mon then
        local ok_scale = pcall(mon.setTextScale, 1)
        local ok_s, w, h = pcall(mon.getSize)
        if ok_scale and ok_s and w == 1 and h == 3 then
          return name, mon
        end
      end
    end
  end
  return nil
end

-- determine_color(runtime, constants): reine Funktion, gibt nur den
-- Farb-Key zurueck (nicht rendert selbst) — separat testbar/nachvollziehbar.
function M.determine_color(runtime, constants)
  local state = runtime.state or {}

  -- 1. GRAU: Anlage bewusst aus.
  if state.rt_global_off_hold == true then return "gray" end
  local power_target = tonumber(state.power_target) or 0
  if power_target <= 0 and state.active_profile ~= "PEAK" then
    -- Kein Auftrag UND nicht mitten in einem PEAK-Anfahrvorgang — echtes
    -- "nichts angefordert", nicht nur ein kurzzeitiger Nulldurchgang.
    return "gray"
  end

  -- 2. ROT: kritische Alerts oder RT im SAFE/EMERGENCY.
  local alert_service = runtime.refs and runtime.refs.alert_service
  local counts = alert_service and alert_service.get_counts_by_severity and alert_service:get_counts_by_severity() or {}
  if (counts.CRITICAL or 0) > 0 then return "red" end

  local nodes = state.nodes or {}
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      local node_state = tostring(node.state or "")
      if node_state == "SAFE" or node_state == "EMERGENCY" then return "red" end
    end
  end

  -- 3. ORANGE: Warnungen (deckt RT_NO_REDUNDANCY, Energy-Fuellstand etc. ab).
  if (counts.WARN or 0) > 0 then return "orange" end

  -- 4. GELB: mindestens ein Node lernt noch Kapazitaet.
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE and node.capacity_ready ~= true then
      return "yellow"
    end
  end

  -- 5. GRUEN: alles normal.
  return "green"
end

-- update(runtime, constants): einmaliger Aufruf pro Tick vom Aufrufer
-- (master/loop.lua), komplett fehlerisoliert.
function M.update(runtime, constants)
  pcall(function()
    local name, mon = find_ampel_monitor()
    if not name or not mon then return end
    local color_key = M.determine_color(runtime, constants)
    local color = COLORS[color_key] or COLORS.gray
    if cache.name == name and cache.last_color == color then return end
    cache.name = name
    cache.last_color = color
    mon.setBackgroundColor(color)
    mon.clear()
  end)
end

return M
