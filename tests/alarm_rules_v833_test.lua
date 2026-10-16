package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-16): "an die Meldungen, Warnungen, Stoerungen muss was
-- dran ... die kommen so schnell wieder, dass es nichts bringt." Viele
-- Meldungen kamen aus normalem Regelbetrieb. core/alert_rules.lua ist neu
-- geschrieben (v833): Fehlalarme gestrichen, feste Klasse je Regel,
-- RT-Probleme kommen von der RT-Node selbst.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local health = require('core.health')
local constants = require('shared.constants')
local R = constants.roles

local function new_rules()
  package.loaded['core.alert_rules'] = nil
  return require('core.alert_rules').new({ alert_raise_after_s = 0, alert_clear_after_s = 0, alert_cooldown_s = 0 })
end

local function by_code(alerts)
  local out = {}
  for _, a in ipairs(alerts or {}) do
    out[a.code] = out[a.code] or {}
    table.insert(out[a.code], a)
  end
  return out
end

local function healthy_rt(id, over)
  local node = {
    id = id, role = R.RT_NODE, state = 'RUNNING', assignment_state = 'active', capacity_max = 1000,
    health = { status = health.status.OK, reasons = {} },
    rt = { problems = {} },
    turbines = {
      { id = 'turbine:t1', rpm = 905, coil_engaged = true },     -- am Ziel
      { id = 'turbine:t2', rpm = 400, coil_engaged = true },     -- abgestellt, bremst
      { id = 'turbine:t3', rpm = 300, coil_engaged = false },    -- faehrt hoch
      { id = 'turbine:t4', rpm = 40, coil_engaged = false },     -- steht
    },
    reactors = { { id = 'reactor_0', rods_level = 80, steam_production = 0 } },
    steam = 0,
  }
  for k, v in pairs(over or {}) do node[k] = v end
  return node
end

-- ══ 1. Normalbetrieb: keine einzige Meldung ═════════════════════════════

do
  local rules = new_rules()
  local nodes = {
    healthy_rt('RT-1'),
    healthy_rt('RT-2'),
    -- Speicher voll: das Ziel, kein Grund fuer eine Meldung.
    { id = 'ENERGY-1', role = R.ENERGY_NODE, stored = 960, capacity = 1000,
      matrices = { { id = 'm1', percent = 0.96 } }, health = { status = health.status.OK, reasons = {} } },
    -- Die Node meldet selbst, sie hoere MASTER gerade nicht -- MASTER hoert
    -- sie aber (sonst kaeme der Status nicht an).
    { id = 'FUEL-1', role = R.FUEL_NODE,
      health = { status = health.status.DEGRADED, reasons = { [health.reasons.COMMS_DOWN] = true } } },
    -- Ein verlorener Timer: die Node laeuft weiter.
    { id = 'REPROC-1', role = R.REPROCESSOR_NODE,
      health = { status = health.status.OK, reasons = { [health.reasons.TIMER_LOST] = true } } },
  }
  local seen = {}
  for step = 0, 120 do
    local alerts = rules:evaluate({ now = 100000 + step * 1000, nodes = nodes, power_target = 500 })
    for _, a in ipairs(alerts) do seen[#seen + 1] = a.code .. ' ' .. tostring(a.message) end
  end
  assert_eq(table.concat(seen, ' | '), '', 'Normalbetrieb meldet nichts')
end

-- Die gestrichenen Regeln gibt es nicht mehr, auch nicht in Grenzlagen.
do
  local rules = new_rules()
  local rt = healthy_rt('RT-1', {
    turbines = { { id = 'turbine:x', rpm = 2500, coil_engaged = true }, { id = 'turbine:y', rpm = 100, coil_engaged = true } },
    steam = 10000, reactors = { { id = 'r', rods_level = 70, steam_production = 10 } },
  })
  local seen = {}
  for step = 0, 60 do
    for _, a in ipairs(rules:evaluate({ now = step * 1000, nodes = { rt }, power_target = 500 })) do seen[a.code] = true end
  end
  for _, code in ipairs({ 'TURBINE_RPM_LOW', 'TURBINE_OVERSPEED', 'COIL_EARLY', 'REACTOR_RODS_STUCK', 'MATRIX_NEAR_FULL' }) do
    assert_true(not seen[code], code .. ' ist gestrichen')
  end
end

-- ══ 2. Node offline: feste Klasse nach Rolle, keine Hochstufung ═════════

do
  local rules = new_rules()
  local nodes = {}
  for _, spec in ipairs({ { 'RT-1', R.RT_NODE }, { 'ENERGY-1', R.ENERGY_NODE }, { 'FUEL-1', R.FUEL_NODE },
                          { 'REPROC-1', R.REPROCESSOR_NODE }, { 'LOG-1', R.LOG_COLLECTOR } }) do
    nodes[#nodes + 1] = { id = spec[1], role = spec[2], offline = true, down_since = 100000,
      health = { status = health.status.DOWN, reasons = { [health.reasons.COMMS_DOWN] = true } } }
  end
  for _, now in ipairs({ 100000, 130000, 400000 }) do
    local got = {}
    for _, a in ipairs(rules:evaluate({ now = now, nodes = nodes }) or {}) do
      if a.code == 'NODE_COMMS_DOWN' then got[a.source.node_id] = a end
    end
    assert_eq(got['RT-1'].severity, 'CRITICAL', 'RT offline ist eine Stoerung (t=' .. now .. ')')
    assert_eq(got['ENERGY-1'].severity, 'CRITICAL', 'ENERGY offline ist eine Stoerung')
    assert_eq(got['FUEL-1'].severity, 'CRITICAL', 'FUEL offline ist eine Stoerung')
    assert_eq(got['REPROC-1'].severity, 'WARN', 'REPROC offline bleibt eine Warnung -- auch nach Minuten')
    assert_eq(got['LOG-1'].severity, 'WARN', 'LOG offline bleibt eine Warnung')
  end
  local last = rules:evaluate({ now = 460000, nodes = nodes })
  assert_true(by_code(last).NODE_COMMS_DOWN[1].message:find('seit 360 s', 1, true) ~= nil, 'Dauer im Text')
  -- Kommt sie wieder, geht die Meldung.
  for _, n in ipairs(nodes) do n.offline = false; n.health = { status = health.status.OK, reasons = {} } end
  local _, clears = rules:evaluate({ now = 470000, nodes = nodes })
  assert_eq(#clears, 5, 'alle fuenf gehen')
end

-- ══ 3. Eingeschraenkt: nur echte Gruende, deutsch, entprellt ════════════

do
  local rules = new_rules()
  local node = { id = 'FUEL-1', role = R.FUEL_NODE,
    health = { status = health.status.DEGRADED, reasons = {
      [health.reasons.NO_STORAGE] = true, [health.reasons.COMMS_DOWN] = true, [health.reasons.TIMER_LOST] = true } } }
  assert_eq(by_code(rules:evaluate({ now = 0, nodes = { node } })).NODE_DEGRADED, nil, 'nicht sofort')
  assert_eq(by_code(rules:evaluate({ now = 9999, nodes = { node } })).NODE_DEGRADED, nil, 'auch nach 9,9 s nicht')
  local a = by_code(rules:evaluate({ now = 10000, nodes = { node } })).NODE_DEGRADED
  assert_true(a and a[1].severity == 'WARN', 'nach 10 s eine Warnung')
  assert_eq(a[1].message, 'FUEL-1: kein Speicher (ME-Bridge)', 'nur der echte Grund, im Klartext')

  -- ENERGY ohne Matrix: das ist MATRIX_MISSING, nicht "eingeschraenkt".
  rules = new_rules()
  local energy = { id = 'ENERGY-1', role = R.ENERGY_NODE, managed = true,
    health = { status = health.status.DEGRADED, reasons = { [health.reasons.NO_MATRIX] = true } } }
  local codes = {}
  for _, now in ipairs({ 0, 11000 }) do
    for _, x in ipairs(rules:evaluate({ now = now, nodes = { energy } })) do codes[x.code] = x end
  end
  assert_true(codes.MATRIX_MISSING ~= nil and codes.MATRIX_MISSING.severity == 'CRITICAL', 'ohne Matrix: Stoerung')
  assert_eq(codes.NODE_DEGRADED, nil, 'nicht doppelt als "eingeschraenkt"')
end

-- ══ 4. Energie niedrig: Abstand zwischen Kommen und Gehen ═══════════════

do
  local rules = new_rules()
  local energy = { id = 'ENERGY-1', role = R.ENERGY_NODE, stored = 0, capacity = 1000,
    health = { status = health.status.OK, reasons = {} } }
  local function at(now, pct)
    energy.stored = pct * 10
    local alerts, clears = rules:evaluate({ now = now, nodes = { energy } })
    return by_code(alerts).ENERGY_LOW, clears
  end
  assert_eq(at(0, 25), nil, '25 %: bis v832 eine Warnung, jetzt Normalbetrieb')
  assert_eq(at(1000, 11), nil, '11 %: noch nichts')
  local a = at(2000, 9)
  assert_true(a and a[1].severity == 'WARN', '9 %: Warnung')
  local _, clears = at(3000, 14)
  assert_eq(#clears, 0, '14 %: bleibt (geht erst ab 15 %)')
  _, clears = at(4000, 15)
  assert_eq(clears[1], 'ENERGY_LOW', '15 %: geht')
  assert_eq(at(5000, 12), nil, '12 % von oben: kommt nicht wieder')
end

-- ══ 5. RT meldet ein Problem ════════════════════════════════════════════

do
  local rules = new_rules()
  local rt = healthy_rt('RT-1')
  rt.rt.problems = { 'liefert 40% vom Soll (4.0k von 10.0k RF/t) seit 6 min', '- turbine_2: 300/900 U/min' }
  local a = by_code(rules:evaluate({ now = 0, nodes = { rt } })).RT_PROBLEM
  assert_true(a ~= nil, 'die Node hat schon entprellt: sofort')
  assert_eq(a[1].severity, 'WARN')
  assert_eq(a[1].title, 'RT meldet ein Problem')
  assert_eq(a[1].message, 'RT-1: liefert 40% vom Soll (4.0k von 10.0k RF/t) seit 6 min (+1) -- Details am RT-Monitor')
  assert_eq(#a[1].details.lines, 2, 'alle Zeilen fuer die Detailansicht')
  assert_eq(a[1].details.lines[2], '- turbine_2: 300/900 U/min')

  rt.rt.problems = {}
  local _, clears = rules:evaluate({ now = 1000, nodes = { rt } })
  assert_eq(clears[1], 'RT_PROBLEM|RT-1', 'leer: geht')

  -- Eine offline RT-Node meldet nur "offline", nicht ihre alten Zeilen.
  rules = new_rules()
  rt.rt.problems = { 'x' }
  rt.offline = true
  local codes = by_code(rules:evaluate({ now = 0, nodes = { rt } }))
  assert_true(codes.NODE_COMMS_DOWN ~= nil and codes.RT_PROBLEM == nil, 'offline: nur das')
end

-- ══ 6. Uebrige Regeln behalten ihre Klasse ══════════════════════════════

do
  local rules = new_rules()
  local rt = healthy_rt('RT-1', { state = 'SAFE',
    health = { status = health.status.DEGRADED, reasons = { [health.reasons.PROTO_MISMATCH] = true } } })
  local fuel = { id = 'FUEL-1', role = R.FUEL_NODE,
    health = { status = health.status.DEGRADED, reasons = { [health.reasons.PROTO_MISMATCH] = true } } }
  local got = {}
  for _, a in ipairs(rules:evaluate({ now = 0, nodes = { rt, fuel } })) do got[a.key] = a end
  assert_eq(got['RT_SAFE_MODE|RT-1'].severity, 'CRITICAL', 'RT im Schutzzustand: Stoerung')
  assert_eq(got['PROTO_MISMATCH|RT-1'].severity, 'CRITICAL', 'Protokoll bei RT: Stoerung')
  assert_eq(got['PROTO_MISMATCH|FUEL-1'].severity, 'WARN', 'Protokoll sonst: Warnung')

  -- Keine RT-Reserve: erst nach einer Minute (MASTER verschiebt selbst).
  rules = new_rules()
  local sole = healthy_rt('RT-1', { capacity_max = 800 })
  local other = healthy_rt('RT-2', { assignment_state = 'standby', capacity_max = 100 })
  assert_eq(by_code(rules:evaluate({ now = 0, nodes = { sole, other }, power_target = 500 })).RT_NO_REDUNDANCY, nil)
  assert_eq(by_code(rules:evaluate({ now = 59000, nodes = { sole, other }, power_target = 500 })).RT_NO_REDUNDANCY, nil)
  local a = by_code(rules:evaluate({ now = 60000, nodes = { sole, other }, power_target = 500 })).RT_NO_REDUNDANCY
  assert_true(a and a[1].severity == 'WARN', 'nach 60 s eine Warnung')

  local rec = rules:evaluate({ now = 70000, nodes = {}, recovery_notice = { active = true, message = 'm' } })
  assert_eq(by_code(rec).UPDATE_RECOVERY[1].severity, 'INFO', 'Update-Rueckfall ist eine Meldung')
end

-- ══ 7. Node vergessen ═══════════════════════════════════════════════════

do
  local rules = new_rules()
  local gone = { id = 'RT-9', role = R.RT_NODE, offline = true }
  rules:evaluate({ now = 0, nodes = { gone, healthy_rt('RT-1') } })
  assert_true(rules.state['NODE_COMMS_DOWN|RT-9'] ~= nil)
  rules:forget_node('RT-9')
  for key in pairs(rules.state) do
    assert_true(not key:find('RT-9', 1, true), 'vergessen: ' .. key)
  end
  assert_true(rules.state['NODE_COMMS_DOWN|RT-1'] ~= nil, 'die anderen bleiben')
end

print('alarm_rules_v833_test.lua: ok')
