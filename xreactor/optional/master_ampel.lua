-- xreactor/optional/master_ampel.lua
--
-- Optionale Peripherie: MASTER-Gesamtampel.
--
-- Zweck: eine zentrale Ampel (1x1 oder 1x3) am MASTER, die NICHT den
-- Zustand eines einzelnen Nodes zeigt (das macht optional/ampel.lua an den
-- Nodes selbst), sondern den Gesamtzustand der kompletten Anlage -- eine
-- einzige Farbe, die alle Nodes/Alerts zusammenfasst.
--
-- Prioritaet der Zustaende (hoechste zuerst -- die erste zutreffende
-- Bedingung gewinnt):
--   1. ROT    -- eine kritische Node (RT, ENERGY oder FUEL) ist offline,
--               ODER mindestens eine Stoerung (CRITICAL) steht an --
--               quittiert oder nicht --, ODER ein RT-Node steht in
--               SAFE/EMERGENCY.
--   2. ROT BLINKEND -- keine Stoerung steht mehr an, aber eine gegangene
--               ist noch nicht quittiert (v834, Betreiber: "Blinken, wenn
--               nur was quittiert werden muss; wenn Stoerung akut ist,
--               rot"). Im Sekundentakt rot/aus.
--   3. GRAU   -- RT-Global-Hold aktiv, oder Leistungsziel 0 (ausser mitten
--               im PEAK-Anfahren): Anlage bewusst aus.
--   4. ORANGE -- mindestens ein WARN-Alert aktiv (deckt u.a. die
--               RT_NO_REDUNDANCY-Warnung und Energy-Fuellstand-Warnungen ab)
--   5. GELB   -- mindestens ein RT-Node lernt gerade seine Kapazitaet
--   6. GRUEN  -- alles normal
--
-- Stoerungen vor Grau (v836, Betreiber auf die Frage, ob Grau eine Stoerung
-- und das Blinken weiter verdecken soll: "Nein"). Bis v835 stand Grau ganz
-- oben -- bei vollem Speicher ist das Leistungsziel 0, also war die Ampel
-- dann grau, auch wenn eine RT-Node ausgefallen war. Das bewusste
-- Abschalten selbst macht nichts rot: RT-Hold setzt die RT-Nodes nur auf
-- "nicht steuerbar" (master/rt_sync.lua), SAFE/EMERGENCY kommt nur von
-- einer echten Schutzausloesung.
--
-- Kritische Node offline (v832): bis v831 stand die Regel nur in diesem
-- Kommentar. Eine ausgefallene Node machte die Ampel nur ueber den Alarm
-- NODE_COMMS_DOWN rot -- erst ~2 s orange, nach ~12 s rot, und gar nicht,
-- wenn der Alarm stummgeschaltet war. Jetzt ist sie rot, sobald MASTER die
-- Node als offline fuehrt, und bleibt es auch, nachdem MASTER sie nach
-- node_offline_purge_after_s (120 s) aus seiner Liste geloescht hat -- bis
-- sie sich wieder meldet oder MASTER neu startet.
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
  black  = colors.black,
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
-- gesucht statt erst nach PROBE_S. critical_memory: siehe
-- offline_critical_nodes(); offline_label: zuletzt ins Log gemeldete
-- ausgefallene Nodes. Beide ueberstehen forget().
local cache = { ampel_name = nil, painted_color = nil, painted_at = nil, next_probe = 0, lost_name = nil,
  critical_memory = {}, offline_label = "" }

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

-- Kritische Rollen: ohne sie laeuft die Anlage nicht weiter -- RT erzeugt
-- den Strom, ENERGY misst den Speicher (ohne ihn regelt MASTER blind),
-- FUEL versorgt die Reaktoren. REPROCESSING, LOG und die VALVE-Nodes unter
-- FUEL sind Nebenaufgaben: faellt eine davon aus, meldet das weiter nur
-- der Alarm NODE_COMMS_DOWN (Regeln 2/3 ueber die Alert-Zaehler).
local function critical_roles(constants)
  local roles = constants and constants.roles or {}
  return {
    [roles.RT_NODE or "RT-NODE"] = true,
    [roles.ENERGY_NODE or "ENERGY-NODE"] = true,
    [roles.FUEL_NODE or "FUEL-NODE"] = true,
  }
end

-- Offline heisst: MASTER hoert nichts mehr von der Node. node.offline setzt
-- master/runtime_ops_rt.lua check_timeouts() nach dem Funk-Timeout, die
-- naechste Meldung der Node loescht es wieder. Bewusst NICHT node.status:
-- der bleibt nach einer Rueckkehr noch OFFLINE, bis die naechste
-- STATUS-Meldung kommt (der Heartbeat setzt ihn aus dem alten
-- health.status DOWN neu) -- das gaebe ein falsches Rot.
--
-- memory (optional, {[node_id] = rolle}): kritische Nodes, die zuletzt
-- offline gesehen wurden. check_timeouts() loescht eine Node, die
-- node_offline_purge_after_s lang offline war, aus state.nodes -- ohne
-- memory waere die Ampel danach wieder gruen, obwohl die Node weiter fehlt.
-- Verschwindet eine Node, die zuletzt online war (Kennung umbenannt), zaehlt
-- sie nicht. Gibt die sortierten Kennungen der fehlenden Nodes zurueck.
function M.offline_critical_nodes(runtime, constants, memory)
  local critical = critical_roles(constants)
  local nodes = (runtime.state and runtime.state.nodes) or {}
  local offline = {}
  local present = {}
  for key, node in pairs(nodes) do
    if type(node) == "table" then
      local id = tostring(node.id or key)
      present[id] = true
      if critical[node.role] and node.offline == true then
        offline[#offline + 1] = id
        if memory then memory[id] = node.role end
      elseif memory then
        memory[id] = nil
      end
    end
  end
  for id in pairs(memory or {}) do
    if not present[id] then offline[#offline + 1] = id end
  end
  table.sort(offline)
  return offline
end

-- Die Farbregeln 1-6 aus dem Kopfkommentar; offline aus
-- offline_critical_nodes().
local function color_for(runtime, constants, offline)
  local state = runtime.state or {}

  -- 1. ROT: kritische Node offline, kritische Alerts, RT im SAFE/EMERGENCY.
  if #offline > 0 then return "red" end

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

  -- 2. ROT BLINKEND: nur noch etwas zu quittieren.
  if (counts.GONE_UNACKED_CRITICAL or 0) > 0 then return "red_blink" end

  -- 3. GRAU: Anlage bewusst aus.
  if state.rt_global_off_hold == true then return "gray" end
  local power_target = tonumber(state.power_target) or 0
  if power_target <= 0 and state.active_profile ~= "PEAK" then
    -- Kein Auftrag UND nicht mitten in einem PEAK-Anfahrvorgang -- echtes
    -- "nichts angefordert", nicht nur ein kurzzeitiger Nulldurchgang.
    return "gray"
  end

  -- 4. ORANGE: Warnungen (deckt RT_NO_REDUNDANCY, Energy-Fuellstand etc. ab).
  if (counts.WARN or 0) > 0 then return "orange" end

  -- 5. GELB: mindestens ein Node lernt noch Kapazitaet.
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE and node.capacity_ready ~= true then
      return "yellow"
    end
  end

  -- 6. GRUEN: alles normal.
  return "green"
end

-- determine_color(runtime, constants, memory): gibt den Farb-Key zurueck
-- (rendert nicht selbst) -- separat testbar/nachvollziehbar -- und als
-- zweiten Wert die Kennungen der ausgefallenen kritischen Nodes. memory
-- siehe offline_critical_nodes(); ohne memory zaehlen nur Nodes in
-- state.nodes.
function M.determine_color(runtime, constants, memory)
  local offline = M.offline_critical_nodes(runtime, constants, memory)
  return color_for(runtime, constants, offline), offline
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

-- Eine abgebaute Node vergessen (Seite MELDUNGEN, "VERGESSEN"): sonst
-- bliebe die Ampel ihretwegen rot, bis MASTER neu startet.
function M.forget_node(node_id)
  cache.critical_memory[tostring(node_id)] = nil
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
    -- Farbe auch ohne Ampel bestimmen: critical_memory muss eine Node, die
    -- offline geht, sehen, bevor MASTER sie loescht -- auch wenn die Ampel
    -- gerade abgezogen ist.
    local color_key, offline = M.determine_color(runtime, constants, cache.critical_memory)
    local offline_label = table.concat(offline or {}, ", ")
    if offline_label ~= cache.offline_label then
      -- Ins MASTER-Log (wie "Node offline: ..."), nicht per print ins
      -- Terminal; nur bei Aenderung.
      local message = offline_label ~= "" and ("[MASTER_AMPEL] kritische Node offline: " .. offline_label)
        or (cache.offline_label ~= "" and "[MASTER_AMPEL] kritische Nodes wieder da") or nil
      if message and type(runtime.log) == "function" then pcall(runtime.log, message, "WARN") end
      cache.offline_label = offline_label
    end
    if not mon then return end
    local color
    if color_key == "red_blink" then
      -- Sekundentakt: update() laeuft dafuer jede Sekunde (master/loop.lua).
      color = (math.floor(now) % 2 == 0) and COLORS.red or COLORS.black
    else
      color = COLORS[color_key] or COLORS.gray
    end
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
