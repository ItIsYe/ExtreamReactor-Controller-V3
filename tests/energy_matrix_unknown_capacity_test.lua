package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Eine Matrix, deren Kapazitaet (noch) nicht gelesen ist, ist nicht
-- "100 % voll".
--
-- Bis v814 fiel nodes/energy/matrix_snapshot_runtime.lua's rebuild_snapshot()
-- bei fehlender Kapazitaet auf den Inhalt zurueck (capacity = stored). Das
-- ging ueber Funk an MASTER: core/alert_rules.lua meldete MATRIX_NEAR_FULL
-- fuer eine Matrix, deren Fuellstand niemand kannte, und die Gesamtanzeigen
-- rechneten den erfundenen Nenner mit. storage_snapshot_runtime.lua hatte
-- denselben Fehler schon abgelegt; jetzt gilt die Regel auch fuer Matrizen.
--
--   1. Matrix ohne lesbare Kapazitaet: Fuellstand nil, Kapazitaet nil,
--      capacity_known = false -- ihr Inhalt zaehlt nur in stored_all
--   2. daneben eine Matrix mit Kapazitaet: der Gesamtfuellstand ist ihrer,
--      Zaehler und Nenner gehoeren zusammen
--   3. MASTERs Alarmregeln melden fuer die unbekannte Matrix kein
--      MATRIX_NEAR_FULL (seit v833 gibt es die Meldung gar nicht mehr)
--   4. ist keine Kapazitaet bekannt, ist der Gesamtfuellstand unbekannt
--      (nil), weder 100 % noch 0 %
--   5. sobald die Kapazitaet lesbar ist, gilt wieder der echte Wert

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local now = 25000
local old_epoch = os.epoch
os.epoch = function() return now end

local matrix_runtime_lib = require('nodes.energy.matrix_snapshot_runtime')

local capacity_readable = false
local blind = {
  getStored = function() return 900 end,
  getCapacity = function()
    if capacity_readable then return 1000 end
    return nil, 'capacity failed'
  end,
  getInput = function() return 5 end,
  getOutput = function() return 6 end,
  features = {},
}
local known = {
  getStored = function() return 500 end,
  getCapacity = function() return 2000 end,
  getInput = function() return 1 end,
  getOutput = function() return 2 end,
  features = {},
}
local config = {
  matrix_metric_poll_interval = 1,
  matrix_metric_call_budget = 16,
  matrix_metric_per_matrix_budget = 4,
  matrix_metric_time_budget_ms = 10000,
  matrix_sample_min_tick_spacing_ms = 1,
}

local function snapshot_for(groups)
  local rt = matrix_runtime_lib.new({ config = config, get_groups = function() return groups end })
  rt:tick(now)
  return rt, rt:get_snapshot(100000)
end

local blind_group = { key = 'matrix-blind', representative = { name = 'matrix_0', adapter = blind }, ports = {} }
local known_group = { key = 'matrix-known', representative = { name = 'matrix_1', adapter = known }, ports = {} }

-- ══ 1./2. Eine unbekannte und eine bekannte Matrix ════════════════════════
local _, snap = snapshot_for({ blind_group, known_group })
local by_key = {}
for _, m in ipairs(snap.matrices) do by_key[m.key] = m end

local b = by_key['matrix-blind']
assert_eq(b.stored, 900, 'der Inhalt der unbekannten Matrix wird weiter gezeigt')
assert_eq(b.percent, nil, 'ohne Kapazitaet ist der Fuellstand unbekannt -- nicht 100 %')
assert_eq(b.capacity, nil, 'ohne Kapazitaet keine erfundene Kapazitaet')
assert_eq(b.capacity_known, false, 'die Matrix sagt, dass ihre Kapazitaet unbekannt ist')
assert_eq(b.status, 'MISSING', 'eine Matrix ohne vollstaendige Probe bleibt MISSING')

local k = by_key['matrix-known']
assert_eq(k.capacity, 2000, 'bekannte Kapazitaet')
assert_eq(k.percent, 0.25, 'bekannter Fuellstand')
assert_eq(k.capacity_known, true, 'bekannte Kapazitaet ist als bekannt markiert')

assert_eq(snap.total.stored, 500, 'Zaehler nur ueber Matrizen mit bekannter Kapazitaet')
assert_eq(snap.total.capacity, 2000, 'Nenner nur ueber Matrizen mit bekannter Kapazitaet')
assert_eq(snap.total.percent, 0.25, 'Gesamtfuellstand aus Zaehler und Nenner, die zusammengehoeren')
assert_eq(snap.total.stored_all, 1400, 'der wahre Gesamtinhalt ueber alle Matrizen')
assert_eq(snap.total.capacity_unknown, 1, 'eine Matrix mit unbekannter Kapazitaet')
assert_eq(snap.stale, true, 'der Schnappschuss bleibt veraltet, solange eine Probe fehlt (MASTERs Lastabwurf laesst ihn aus)')

-- ══ 3. MASTERs Alarmregeln ════════════════════════════════════════════════
do
  local health = require('core.health')
  local constants = require('shared.constants')
  local alert_rules = require('core.alert_rules').new({
    alert_raise_after_s = 0, alert_clear_after_s = 0, alert_cooldown_s = 0,
    comms_down_warn_secs = 0, comms_down_crit_secs = 10,
  })
  local alerts = select(1, alert_rules:evaluate({
    now = now,
    nodes = {
      {
        -- Die Rolle aus den Konstanten ("ENERGY-NODE"): mit einem
        -- geratenen 'ENERGY_NODE' liefe die Matrixregel gar nicht und der
        -- Test bestuende immer.
        id = 'ENERGY-1', role = constants.roles.ENERGY_NODE, status = health.status.OK,
        health = { status = health.status.OK, reasons = {} },
        matrix_count = 2, storage_bound_count = 0,
        stored = snap.total.stored, capacity = snap.total.capacity,
        matrices = snap.matrices,
      },
    },
  }))
  for _, alert in ipairs(alerts or {}) do
    assert_true(not (alert.code == 'MATRIX_NEAR_FULL'),
      'MATRIX_NEAR_FULL fuer eine Matrix mit unbekanntem Fuellstand: ' .. tostring(alert.message))
  end

  -- Seit v833 meldet MASTER eine volle Matrix ueberhaupt nicht mehr: ein
  -- voller Speicher ist das Ziel (die IDLE-Schwelle liegt standardmaessig
  -- ebenfalls bei 90 %), und die Warnung pendelte im Normalbetrieb um diese
  -- Grenze. Also auch fuer eine bekannte, volle Matrix nichts.
  local full = alert_rules:evaluate({
    now = now,
    nodes = {
      {
        id = 'ENERGY-2', role = constants.roles.ENERGY_NODE, status = health.status.OK,
        health = { status = health.status.OK, reasons = {} },
        matrix_count = 1, storage_bound_count = 0, stored = 950, capacity = 1000,
        matrices = { { id = 'matrix-full', key = 'matrix-full', percent = 0.95, capacity = 1000, capacity_known = true } },
      },
    },
  })
  for _, alert in ipairs(full or {}) do
    assert_true(alert.code ~= 'MATRIX_NEAR_FULL', 'eine volle Matrix ist kein Grund fuer eine Meldung (v833)')
  end
end

-- ══ 4. Keine Kapazitaet bekannt ═══════════════════════════════════════════
local rt_blind
rt_blind, snap = snapshot_for({ blind_group })
assert_eq(snap.total.percent, nil, 'ohne jede bekannte Kapazitaet ist der Gesamtfuellstand unbekannt')
assert_eq(snap.total.capacity, 0, 'kein Nenner')
assert_eq(snap.total.stored, 0, 'kein Zaehler ohne Nenner')
assert_eq(snap.total.stored_all, 900, 'der Inhalt geht trotzdem nicht verloren')

-- Ohne Matrizen bleibt es bei 0 wie bisher.
_, snap = snapshot_for({})
assert_eq(snap.total.percent, 0, 'ohne Matrizen: 0')

-- ══ 5. Kapazitaet wird lesbar ═════════════════════════════════════════════
capacity_readable = true
now = now + 5000
rt_blind:tick(now)
snap = rt_blind:get_snapshot(100000)
assert_eq(snap.matrices[1].capacity, 1000, 'gelesene Kapazitaet')
assert_eq(snap.matrices[1].percent, 0.9, 'echter Fuellstand')
assert_eq(snap.matrices[1].capacity_known, true, 'jetzt bekannt')
assert_eq(snap.total.percent, 0.9, 'echter Gesamtfuellstand')
assert_eq(snap.total.capacity_unknown, 0, 'keine unbekannte Kapazitaet mehr')

-- ══ 6. MASTERs Energieseite: unbekannt bleibt unbekannt ═══════════════════
-- master/ui_controller.lua machte aus einem fehlenden Fuellstand 0 %; fuer
-- eine Matrix mit capacity_known = false bleibt er jetzt nil, und
-- master/ui/energy.lua zeigt "n/a".
do
  package.loaded['master.ui_controller'] = nil
  local ui_controller = require('master.ui_controller')
  local captured
  local controller = ui_controller.new({
    constants = {
      roles = { ENERGY_NODE = 'ENERGY_NODE', RT_NODE = 'RT_NODE', FUEL_NODE = 'FUEL_NODE', REPROCESSOR_NODE = 'REPROCESSOR_NODE' },
      status_levels = { OK = 'OK', WARNING = 'WARNING', EMERGENCY = 'EMERGENCY', LIMITED = 'LIMITED', OFFLINE = 'OFFLINE', MANUAL = 'MANUAL' },
      node_states = { OFF = 'OFF' },
    },
    health = { reasons_list = function() return {} end, summarize_bindings = function() return nil end },
    config = {},
    nodes = {
      E = { id = 'E', role = 'ENERGY_NODE', status = 'OK', stored = 0, capacity = 0, input = 0, output = 0,
        matrices = {
          { id = 'm-blind', stored = 900, capacity_known = false },
          { id = 'm-known', stored = 500, capacity = 2000, percent = 0.25, capacity_known = true },
        } },
    },
    alarms = {},
    comms = { get_diagnostics = function() return {} end },
    sequencer = { ramp_profile = {}, state = 'idle', queue = {}, active = nil },
    view_manager = { render = function(_, _, data) captured = data.energy; return {} end },
    trends = { is_dirty = function() return false end, clear_dirty = function() end },
    trend_cache = { energy = {}, energy_arrow = '-' },
    state = { last_draw = 0, power_target = 0, active_profile = 'BASELOAD', auto_profile = false,
      critical_blink_until = 0, monitor_cache = { list = {} } },
    calc = { get_power_target = function() return 0 end, get_active_profile = function() return 'BASELOAD' end,
      get_auto_profile = function() return false end },
  })
  controller.draw()
  local rows = {}
  for _, m in ipairs(captured and captured.matrices or {}) do rows[m.id] = m end
  assert_true(rows['m-blind'] ~= nil, 'MASTER fuehrt die unbekannte Matrix')
  assert_eq(rows['m-blind'].percent, nil, 'MASTER: unbekannter Fuellstand bleibt unbekannt (nicht 0 %)')
  assert_eq(rows['m-known'].percent, 25, 'MASTER: bekannter Fuellstand in Prozent')

  local energy_page = require('master.ui.energy')
  local texts = {}
  local mon = setmetatable({
    getSize = function() return 100, 40 end,
    write = function(t) texts[#texts + 1] = t end,
  }, { __index = function() return function() end end })
  local ok, err = pcall(energy_page.render or energy_page, mon, captured)
  assert_true(ok, 'MASTERs Energieseite muss eine unbekannte Matrix zeichnen koennen: ' .. tostring(err))
end

os.epoch = old_epoch
print('ok energy_matrix_unknown_capacity_test')
