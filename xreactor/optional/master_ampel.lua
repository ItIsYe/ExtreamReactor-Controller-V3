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
-- (1x1 oder 1x3, auto-detected, pcall-isoliert), aber als eigenstaendiges
-- Modul, da die Statuslogik hier komplett anders ist (Gesamtanlage statt
-- Einzelnode) und am MASTER laeuft statt an einzelnen Nodes.
--
-- Selbstheilung (v829, wie optional/ampel.lua): spaetestens alle REPAINT_S
-- Sekunden neu malen -- bis v828 nur bei Farbwechsel, ein Monitor ohne
-- Inhalt (Chunk neu geladen, Skala von anderer Stelle umgestellt -- z.B.
-- core/monitor_manager.lua's Auto-Skala) blieb sonst schwarz. Eine
-- verschwundene Ampel wird sofort neu gesucht.

local M = {}

-- Muessen die echten colors-API-Bitmask-Konstanten sein, keine rohen
-- RGB-Hex-Werte -- mon.setBackgroundColor() akzeptiert nur Zweierpotenzen.
local COLORS = {
  green  = colors.green,
  yellow = colors.yellow,
  orange = colors.orange,
  red    = colors.red,
  gray   = colors.gray,
}

M.REPAINT_S = 10
M.PROBE_S = 60

-- Ampel-Form bei Skala 1: dieselbe Regel wie adapters/monitor.lua
-- (1x1 = 7x5, 1x3 = 7x17-21).
local function local_is_ampel_shape(w, h)
  return w == 7 and (h == 5 or (h >= 17 and h <= 21))
end
local ok_adapter, monitor_adapter = pcall(require, "adapters.monitor")
local is_ampel_shape = (ok_adapter and type(monitor_adapter) == "table"
  and type(monitor_adapter.is_ampel_shape) == "function") and monitor_adapter.is_ampel_shape
  or local_is_ampel_shape

local function now_s()
  return (os.clock and os.clock()) or 0
end

-- lost_name: zuletzt verlorene Ampel -- taucht sie wieder auf, wird sofort
-- gesucht statt erst nach PROBE_S.
local cache = { ampel_name = nil, painted_color = nil, painted_at = nil, next_probe = 0, lost_name = nil }

-- Fix: anders als optional/ampel.lua (ein Node, EIN bekannter Hauptmonitor,
-- per Name ausgeschlossen) hatte diese MASTER-Variante gar keinen
-- Ausschluss -- sie hat bei JEDER Sondierung (alle ~60s, solange keine
-- Ampel gefunden ist) ALLE MASTER-eigenen Monitore durchprobiert,
-- einschliesslich der 3 primaeren Displays (Overview/RT/Energy) und aller
-- AUX-Monitore: TextScale kurzzeitig auf 1 gesetzt, Groesse geprueft,
-- wieder zurueckgesetzt -- UND fuer jeden Nicht-Treffer eine Diagnosezeile
-- gedruckt. Das erzeugte Dauerspam ("kein Treffer" fuer Monitore, die nie
-- eine Ampel sein sollten) und kurzzeitiges Skalen-Flackern auf den echten
-- Anzeigen. known_names (aus M.update(), von view_manager.sessions) schliesst
-- alle bereits als MASTER-Monitor gebundenen Peripherals aus, bevor
-- ueberhaupt ihre Skala angefasst wird. seen_non_match droesselt die
-- Diagnosezeile zusaetzlich auf einmal pro (noch unbekanntem) Kandidaten,
-- statt bei jeder Sondierung erneut zu drucken.
local seen_non_match = {}

local function find_ampel_monitor(known_names)
  if not peripheral or type(peripheral.getNames) ~= "function" then return nil end
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return nil end
  for _, name in ipairs(names) do
    if not (known_names and known_names[name]) then
      local ok_t, ptype = pcall(peripheral.getType, name)
      if ok_t and tostring(ptype):find("monitor", 1, true) then
        local ok_w, mon = pcall(peripheral.wrap, name)
        if ok_w and mon then
          local ok_orig, orig_scale = pcall(mon.getTextScale)
          local ok_scale = pcall(mon.setTextScale, 1)
          local ok_s, w, h = pcall(mon.getSize)
          if ok_scale and ok_s and type(w) == "number" and type(h) == "number" and is_ampel_shape(w, h) then
            seen_non_match[name] = nil
            pcall(print, "[MASTER_AMPEL] Ampel gefunden: " .. tostring(name) .. " (" .. (h == 5 and "1x1" or "1x3") .. ")")
            return name, mon
          end
          if ok_s and type(w) == "number" and not seen_non_match[name] then
            seen_non_match[name] = true
            pcall(print, "[MASTER_AMPEL] Kandidat " .. tostring(name) .. " bei Skala 1: w=" .. tostring(w) .. " h=" .. tostring(h) .. " (erwartet 7x5 fuer 1x1 oder 7x17-21 fuer 1x3, kein Treffer)")
          end
          if ok_scale and ok_orig and type(orig_scale) == "number" then
            pcall(mon.setTextScale, orig_scale)
          end
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
  local counts = alert_service and alert_service.get_counts and alert_service:get_counts() or {}
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

-- Ampel vergessen; retry_now: sofort neu suchen (abgezogen/umgebaut),
-- sonst erst nach PROBE_S (Malen scheiterte -- nicht jeden Tick neu
-- sondieren).
local function forget(reason, retry_now)
  if cache.ampel_name then
    pcall(print, "[MASTER_AMPEL] Ampel " .. tostring(cache.ampel_name) .. " weg (" .. tostring(reason) .. ") -- suche neu")
  end
  cache.lost_name = cache.ampel_name or cache.lost_name
  cache.ampel_name = nil
  cache.painted_color = nil
  cache.painted_at = nil
  cache.next_probe = retry_now and 0 or (now_s() + M.PROBE_S)
end

-- Alle bereits als MASTER-Monitor gebundenen Peripherals (die 3 primaeren
-- Displays plus jeder AUX-Monitor, siehe master/monitor_sessions.lua) --
-- keiner von ihnen kann jemals die Ampel sein.
local function known_monitor_names(runtime)
  local known_names = {}
  local sessions = runtime.refs and runtime.refs.view_manager and runtime.refs.view_manager.sessions
  if sessions and sessions.get_sessions then
    local ok_sessions, list = pcall(sessions.get_sessions, sessions)
    if ok_sessions and type(list) == "table" then
      for _, session in ipairs(list) do
        if session and session.name then known_names[session.name] = true end
      end
    end
  end
  return known_names
end

-- update(runtime, constants): einmaliger Aufruf pro Tick vom Aufrufer
-- (master/loop.lua), komplett fehlerisoliert.
function M.update(runtime, constants)
  pcall(function()
    local now = now_s()
    local mon
    if cache.ampel_name then
      if not peripheral.isPresent or peripheral.isPresent(cache.ampel_name) then
        local ok_w, wrapped = pcall(peripheral.wrap, cache.ampel_name)
        if ok_w and wrapped then mon = wrapped else forget("nicht mehr erreichbar", true) end
      else
        forget("nicht mehr angeschlossen", true)
      end
    end
    if not cache.ampel_name and cache.lost_name and peripheral.isPresent
        and peripheral.isPresent(cache.lost_name) then
      cache.next_probe = 0 -- die verlorene Ampel ist wieder angeschlossen
      cache.lost_name = nil
    end
    if not cache.ampel_name and now >= cache.next_probe then
      local name, found = find_ampel_monitor(known_monitor_names(runtime))
      cache.next_probe = now + M.PROBE_S
      if name and found then
        cache.ampel_name = name
        mon = found
      end
    end
    if not mon then return end
    local color_key = M.determine_color(runtime, constants)
    local color = COLORS[color_key] or COLORS.gray
    local due = cache.painted_color ~= color or cache.painted_at == nil
      or now - cache.painted_at >= M.REPAINT_S
    if not due then return end
    local ok_paint = pcall(function()
      mon.setBackgroundColor(color)
      mon.clear()
    end)
    if ok_paint then
      cache.painted_color = color
      cache.painted_at = now
    else
      forget("Malen gescheitert", false)
    end
  end)
end

return M
