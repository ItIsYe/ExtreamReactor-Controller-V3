package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-16): "Dann behebe das mit der Master-Ampel". Der
-- Kopfkommentar von optional/master_ampel.lua versprach ROT, wenn eine
-- kritische Node offline ist -- eine Regel dafuer gab es nicht. Eine
-- ausgefallene Node machte die Ampel nur ueber den Alarm NODE_COMMS_DOWN
-- rot (erst ~2 s orange, nach ~12 s rot) und gar nicht, wenn der Alarm
-- stummgeschaltet war.
--
-- Jetzt: RT, ENERGY oder FUEL offline -> rot, sobald MASTER die Node als
-- offline fuehrt, auch nachdem MASTER sie aus state.nodes geloescht hat.
-- Grau (Anlage bewusst aus) geht weiter vor.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

_G.colors = { green = 1, yellow = 2, orange = 4, red = 8, gray = 16 }
local clock = 0
os.clock = function() return clock end

local constants = {
  roles = {
    MASTER = 'MASTER', RT_NODE = 'RT-NODE', ENERGY_NODE = 'ENERGY-NODE', FUEL_NODE = 'FUEL-NODE',
    REPROCESSOR_NODE = 'REPROCESSOR-NODE', LOG_COLLECTOR = 'LOG_COLLECTOR', VALVE_NODE = 'VALVE-NODE',
  },
  status_levels = { OK = 'OK', OFFLINE = 'OFFLINE' },
}

local function fresh_module()
  package.loaded['optional.master_ampel'] = nil
  return require('optional.master_ampel')
end

local function node(id, role, over)
  local n = { id = id, role = role, status = 'OK', offline = false, stale = false, state = 'RUNNING', capacity_ready = true }
  for k, v in pairs(over or {}) do n[k] = v end
  return n
end

-- Laufende Anlage: Auftrag da, keine Alarme, alle Nodes online.
local function world(over)
  local counts = {}
  local rt = {
    state = { rt_global_off_hold = false, power_target = 100, active_profile = 'BASELOAD', nodes = {
      ['RT-1'] = node('RT-1', 'RT-NODE'),
      ['RT-2'] = node('RT-2', 'RT-NODE'),
      ['ENERGY-1'] = node('ENERGY-1', 'ENERGY-NODE'),
      ['FUEL-1'] = node('FUEL-1', 'FUEL-NODE'),
      ['REPROC-1'] = node('REPROC-1', 'REPROCESSOR-NODE'),
      ['LOG-1'] = node('LOG-1', 'LOG_COLLECTOR'),
    } },
    refs = { alert_service = { get_counts = function() return counts end } },
  }
  if over then over(rt, counts) end
  return rt
end

-- So markiert master/runtime_ops_rt.lua check_timeouts() eine Node.
local function go_offline(n)
  n.status = 'OFFLINE'; n.offline = true; n.stale = true; n.managed = false
end

local ampel = fresh_module()

-- ══ 1. Kritische Rollen offline: rot ═══════════════════════════════════

assert_eq(ampel.determine_color(world(), constants), 'green', 'alles online: gruen')
for _, id in ipairs({ 'RT-1', 'ENERGY-1', 'FUEL-1' }) do
  local rt = world(function(w) go_offline(w.state.nodes[id]) end)
  local color, offline = ampel.determine_color(rt, constants)
  assert_eq(color, 'red', id .. ' offline ist rot -- ohne jeden Alarm')
  assert_eq(table.concat(offline, ','), id, 'die ausgefallene Node wird genannt')
end
do
  local rt = world(function(w) go_offline(w.state.nodes['RT-2']); go_offline(w.state.nodes['FUEL-1']) end)
  local _, offline = ampel.determine_color(rt, constants)
  assert_eq(table.concat(offline, ','), 'FUEL-1,RT-2', 'mehrere, sortiert')
end

-- ══ 2. Nebenaufgaben: nicht ueber diese Regel ══════════════════════════

for _, id in ipairs({ 'REPROC-1', 'LOG-1' }) do
  local rt = world(function(w) go_offline(w.state.nodes[id]) end)
  local color, offline = ampel.determine_color(rt, constants)
  assert_eq(color, 'green', id .. ' offline: die Regel greift nicht (das macht der Alarm)')
  assert_eq(#offline, 0)
end
do
  local rt = world(function(w)
    w.state.nodes['VALVE-1'] = node('VALVE-1', 'VALVE-NODE'); go_offline(w.state.nodes['VALVE-1'])
    w.state.nodes['M'] = node('M', 'MASTER'); go_offline(w.state.nodes['M'])
    w.state.nodes['X'] = node('X', 'UNKNOWN'); go_offline(w.state.nodes['X'])
  end)
  assert_eq(ampel.determine_color(rt, constants), 'green', 'VALVE/MASTER/unbekannt zaehlen nicht')
  -- Der Alarm-Weg bleibt: NODE_COMMS_DOWN wird nach ~12 s CRITICAL.
  rt = world(function(w, counts) go_offline(w.state.nodes['REPROC-1']); counts.CRITICAL = 1 end)
  assert_eq(ampel.determine_color(rt, constants), 'red', 'ueber den kritischen Alarm weiter rot')
end

-- ══ 3. Nur das Funk-Merkmal zaehlt, nicht node.status ══════════════════

do
  -- Nach der Rueckkehr loescht die erste Meldung node.offline sofort;
  -- node.status bleibt bis zur naechsten STATUS-Meldung OFFLINE.
  local rt = world(function(w) w.state.nodes['RT-1'].status = 'OFFLINE' end)
  assert_eq(ampel.determine_color(rt, constants), 'green', 'kein falsches Rot direkt nach der Rueckkehr')
end

-- ══ 4. Stoerungen gehen vor Grau (v836); Rot vor Orange und Gelb ═══════

do
  -- Betreiber auf die Frage, ob Grau eine Stoerung und das Blinken weiter
  -- verdecken soll: "Nein".
  local rt = world(function(w) go_offline(w.state.nodes['RT-1']); w.state.rt_global_off_hold = true end)
  local color, offline = ampel.determine_color(rt, constants)
  assert_eq(color, 'red', 'RT-Global-Hold mit ausgefallener Node: rot')
  assert_eq(table.concat(offline, ','), 'RT-1', 'mit der Liste')
  rt = world(function(w) go_offline(w.state.nodes['RT-1']); w.state.power_target = 0 end)
  assert_eq(ampel.determine_color(rt, constants), 'red', 'Leistungsziel 0 (voller Speicher) mit ausgefallener Node: rot')
  rt = world(function(w, counts) w.state.power_target = 0; counts.CRITICAL = 1 end)
  assert_eq(ampel.determine_color(rt, constants), 'red', 'eine anstehende Stoerung kommt bei Grau durch')
  rt = world(function(w) w.state.power_target = 0; w.state.nodes['RT-1'].state = 'EMERGENCY' end)
  assert_eq(ampel.determine_color(rt, constants), 'red', 'RT im Schutzzustand kommt bei Grau durch')
  rt = world(function(w, counts) w.state.rt_global_off_hold = true; counts.GONE_UNACKED_CRITICAL = 1 end)
  assert_eq(ampel.determine_color(rt, constants), 'red_blink', 'das Blinken kommt bei Grau durch')
  -- Ohne Stoerung bleibt die bewusst abgeschaltete Anlage grau -- auch mit
  -- einer Warnung oder einem lernenden RT-Node.
  rt = world(function(w, counts) w.state.rt_global_off_hold = true; counts.WARN = 3 end)
  assert_eq(ampel.determine_color(rt, constants), 'gray', 'RT-Global-Hold, nur Warnungen: grau')
  rt = world(function(w) w.state.power_target = 0; w.state.nodes['RT-1'].capacity_ready = false end)
  assert_eq(ampel.determine_color(rt, constants), 'gray', 'Leistungsziel 0, RT lernt: grau')
  rt = world(function(w) w.state.power_target = 0 end)
  assert_eq(ampel.determine_color(rt, constants), 'gray', 'Leistungsziel 0, alles gut: grau')
  rt = world(function(w) w.state.power_target = 0; w.state.active_profile = 'PEAK' end)
  assert_eq(ampel.determine_color(rt, constants), 'green', 'PEAK-Anfahren ist nicht grau')
  rt = world(function(w, counts) go_offline(w.state.nodes['ENERGY-1']); counts.WARN = 2 end)
  assert_eq(ampel.determine_color(rt, constants), 'red', 'rot vor orange')
  rt = world(function(w) go_offline(w.state.nodes['FUEL-1']); w.state.nodes['RT-1'].capacity_ready = false end)
  assert_eq(ampel.determine_color(rt, constants), 'red', 'rot vor gelb')
  rt = world(function(w) w.state.nodes['RT-1'].capacity_ready = false end)
  assert_eq(ampel.determine_color(rt, constants), 'yellow', 'die anderen Regeln bleiben')
end

-- ══ 5. Gedaechtnis: geloeschte Node bleibt rot, bis sie zurueck ist ═══

do
  local memory = {}
  local rt = world()
  go_offline(rt.state.nodes['RT-2'])
  assert_eq(ampel.determine_color(rt, constants, memory), 'red')
  rt.state.nodes['RT-2'] = nil -- check_timeouts() loescht nach 120 s
  local color, offline = ampel.determine_color(rt, constants, memory)
  assert_eq(color, 'red', 'nach dem Loeschen weiter rot')
  assert_eq(table.concat(offline, ','), 'RT-2')
  assert_eq(ampel.determine_color(rt, constants), 'green', 'ohne Gedaechtnis waere es gruen (der alte Fehler)')

  rt.state.nodes['RT-2'] = node('RT-2', 'RT-NODE') -- meldet sich wieder
  assert_eq(ampel.determine_color(rt, constants, memory), 'green', 'zurueck: gruen')
  assert_eq(memory['RT-2'], nil, 'und vergessen')

  -- Verschwindet eine Node, die zuletzt online war (Kennung umbenannt),
  -- ist das kein Ausfall.
  rt.state.nodes['RT-2'] = nil
  assert_eq(ampel.determine_color(rt, constants, memory), 'green', 'online verschwunden: kein Rot')

  -- Geloeschte und noch gefuehrte Nodes zusammen, sortiert (die geloeschte
  -- kommt erst nach den gefuehrten dazu).
  go_offline(rt.state.nodes['ENERGY-1'])
  ampel.determine_color(rt, constants, memory)
  rt.state.nodes['ENERGY-1'] = nil
  go_offline(rt.state.nodes['RT-1'])
  local _, offline = ampel.determine_color(rt, constants, memory)
  assert_eq(table.concat(offline, ','), 'ENERGY-1,RT-1', 'sortiert')
end

do
  -- Auch waehrend Grau lernt das Gedaechtnis mit: Node faellt bei vollem
  -- Speicher aus, wird geloescht, dann wird wieder Leistung angefordert.
  local memory = {}
  local rt = world(function(w) w.state.power_target = 0 end)
  go_offline(rt.state.nodes['ENERGY-1'])
  assert_eq(ampel.determine_color(rt, constants, memory), 'red', 'auch bei vollem Speicher rot (v836)')
  rt.state.nodes['ENERGY-1'] = nil
  assert_eq(ampel.determine_color(rt, constants, memory), 'red', 'nach dem Loeschen weiter rot')
  rt.state.power_target = 100
  assert_eq(ampel.determine_color(rt, constants, memory), 'red', 'die waehrend Grau ausgefallene Node fehlt weiter')
end

-- ══ 6. Echter Pfad: update() malt rot, auch nach dem Loeschen ═══════════

do
  ampel = fresh_module()
  local painted = {}
  local mon = {
    getTextScale = function() return 1 end, setTextScale = function() end,
    getSize = function() return 7, 19 end,
    setBackgroundColor = function(c) painted[#painted + 1] = c end, clear = function() end,
  }
  local attached = true
  _G.peripheral = {
    getNames = function() return attached and { 'ampel' } or {} end,
    getType = function() return 'monitor' end,
    wrap = function() return attached and mon or nil end,
    isPresent = function() return attached end,
  }
  local logged = {}
  local real_print = print
  _G.print = function() end -- Fund-/Verlust-Zeilen der Ampel
  local function tick(rt)
    clock = clock + 11 -- ueber REPAINT_S: jedes update() malt
    ampel.update(rt, constants)
    return painted[#painted]
  end

  local rt = world()
  rt.log = function(line, level) logged[#logged + 1] = { line = tostring(line), level = level } end
  assert_eq(tick(rt), colors.green, 'update: gruen')
  go_offline(rt.state.nodes['RT-1'])
  assert_eq(tick(rt), colors.red, 'update: RT offline -> rot')
  rt.state.nodes['RT-1'] = nil
  assert_eq(tick(rt), colors.red, 'update: nach dem Loeschen weiter rot (Gedaechtnis im Modul)')

  -- Ampel kurz abgezogen: das Gedaechtnis lernt trotzdem weiter.
  attached = false
  go_offline(rt.state.nodes['FUEL-1'])
  tick(rt)
  rt.state.nodes['FUEL-1'] = nil
  rt.state.nodes['RT-1'] = node('RT-1', 'RT-NODE')
  tick(rt)
  attached = true
  assert_eq(tick(rt), colors.red, 'FUEL fiel ohne Ampel aus und fehlt weiter')
  rt.state.nodes['FUEL-1'] = node('FUEL-1', 'FUEL-NODE')
  assert_eq(tick(rt), colors.green, 'alle zurueck: gruen')

  -- Seite MELDUNGEN, "VERGESSEN" (v835): eine abgebaute Node haelt die
  -- Ampel nicht mehr bis zum Neustart rot.
  go_offline(rt.state.nodes['FUEL-1'])
  tick(rt)
  rt.state.nodes['FUEL-1'] = nil
  assert_eq(tick(rt), colors.red, 'abgebaut: rot')
  ampel.forget_node('FUEL-1')
  assert_eq(tick(rt), colors.green, 'vergessen: gruen')
  _G.print = real_print

  -- Ins MASTER-Log, nur bei Aenderung.
  local offline_lines, back_lines = {}, 0
  for _, entry in ipairs(logged) do
    assert_eq(entry.level, 'WARN', 'Stufe WARN')
    local ids = entry.line:match('^%[MASTER_AMPEL%] kritische Node offline: (.+)$')
    if ids then offline_lines[#offline_lines + 1] = ids end
    if entry.line == '[MASTER_AMPEL] kritische Nodes wieder da' then back_lines = back_lines + 1 end
  end
  assert_eq(table.concat(offline_lines, ' | '), 'RT-1 | FUEL-1, RT-1 | FUEL-1 | FUEL-1',
    'eine Meldung je Aenderung, nicht je Takt')
  assert_eq(back_lines, 2, 'Entwarnung je Rueckkehr')
  assert_eq(#logged, 6, 'sonst nichts')
end

-- ══ 7. Der Kopfkommentar verspricht nichts mehr, was fehlt ══════════════

do
  local f = assert(io.open('xreactor/optional/master_ampel.lua', 'r'))
  local src = f:read('*a'); f:close()
  assert_true(src:find('als kritisch markierte', 1, true) == nil, 'alte, nie umgesetzte Formulierung ist weg')
  assert_true(src:find('leichte, nicht-kritische Abweichung', 1, true) == nil, 'auch diese Gelb-Regel gab es nie')
  assert_true(src:find('eine kritische Node (RT, ENERGY oder FUEL) ist offline', 1, true) ~= nil,
    'die Regel steht im Kopfkommentar')
end

print('master_ampel_critical_offline_test.lua: ok')
