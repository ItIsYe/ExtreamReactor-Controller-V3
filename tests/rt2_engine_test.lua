package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Der Knoten legt keine Lerndateien mehr ab (keine Kapazitaet, kein
-- Anlagenprofil, keine Turbinenkennlinien), deshalb braucht dieser Test
-- auch keine fs/textutils-Attrappe mehr. Nur die Uhr, weil das
-- Stellintervall des Reglers sie liest.
local clock_ms = 1000000
os.epoch = function() return clock_ms end
local function advance(ms) clock_ms = clock_ms + (ms or 1000) end

local rt2_engine = require('nodes.rt.rt2_engine')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- Fake adapters standing in for adapters/turbine.lua / adapters/reactor.lua --
-- plain functions, no CC:Tweaked globals, matching the dependency-
-- injection style rt2_adapter_test.lua already established.
local turbine_hardware = {
  T1 = { rpm = 900, energy = 100, coil_engaged = true, flow = 4000, active = true },
}
local reactor_hardware = {
  R1 = { steam_fill_ratio = 0.5, control_rod_level = 80, active = true },
}
local applied_flow, applied_coil, applied_rods, applied_active, applied_turbine_active = {}, {}, nil, nil, {}

local fake_ctx = {
  config = { turbines = { 'T1' }, reactors = { 'R1' } },
  CONFIG = { LOG_PREFIX = 'RT' },
  log = function() end,
  adapters = {
    turbine = {
      inspect = function(name) return turbine_hardware[name] end,
      set_flow = function(name, value) applied_flow[name] = value; return true end,
      set_coils = function(name, engaged) applied_coil[name] = engaged; return true end,
      set_active = function(name, enabled) applied_turbine_active[name] = enabled; return true end,
    },
    reactor = {
      inspect = function(name) return reactor_hardware[name] end,
      apply_rod_level = function(name, level) applied_rods = level; return true end,
      set_active = function(name, enabled) applied_active = enabled; return true end,
    },
  },
}

rt2_engine.init({})

-- Es gibt keine Lernphase mehr: der erste Takt mit Hardware ist Betrieb.
-- Ohne MASTER heisst das AUTONOM, und dort faehrt jede Turbine das feste
-- Ziel.
local result = rt2_engine.tick(fake_ctx)
assert_eq(result.state, rt2_state.states.AUTONOM, 'first tick with hardware and no MASTER runs AUTONOM')
assert_eq(result.turbines[1].target_rpm, 900, 'AUTONOM targets the fixed RPM')
-- T1 reads exactly 900 with the coil engaged: it is AT its target, so the
-- controller deliberately writes nothing (rt2_turbine's Ruhezone -- see
-- SETTLE_BAND_RPM). That is the whole point of the change: a settled
-- turbine is left alone instead of being nudged every tick.
assert_true(applied_flow.T1 == nil,
  'a turbine sitting exactly on its target must not be written to at all')
assert_eq(result.turbines[1].flow_decision.reason, 'SETTLED',
  'and the decision must say so')

assert_true(applied_coil.T1 == true, 'the coil decision must have been written to the fake turbine adapter')
assert_true(applied_rods ~= nil, 'the rod decision must have been written to the fake reactor adapter')
assert_true(applied_active == nil, 'a reactor already reading active=true must not trigger a set_active write')
assert_true(applied_turbine_active.T1 == nil, 'a turbine already reading active=true must not trigger a set_active write')

-- ...but a turbine OFF its target must still be written through the full
-- chain (rt2_engine -> rt2_adapter -> the fake adapter). Sonst waere die
-- Ruhezone oben nicht von "die Kette schreibt gar nichts" zu
-- unterscheiden.
turbine_hardware.T1.rpm = 700
advance(5000)
rt2_engine.tick(fake_ctx)
assert_true(applied_flow.T1 ~= nil, 'the flow decision must have been written to the fake turbine adapter')
turbine_hardware.T1.rpm = 900
-- Der Zwischen-Takt oben hat bei 700 RPM die Spule geloest; der naechste
-- Takt bei 900 kuppelt sie wieder ein, also hier nichts von Hand setzen.

-- A reactor/turbine reading active=false must be turned back on through
-- the same full adapter chain (rt2_engine -> rt2_adapter -> the fake
-- adapter's set_active), not just decided and dropped.
reactor_hardware.R1.active = false
turbine_hardware.T1.active = false
advance(5000)
result = rt2_engine.tick(fake_ctx)
assert_eq(applied_active, true, 'a reactor reading active=false must be turned on via set_active(name, true, ...)')
assert_eq(applied_turbine_active.T1, true, 'a turbine reading active=false must be turned on via set_active(name, true, ...)')
reactor_hardware.R1.active = true
turbine_hardware.T1.active = true
applied_active = nil

-- status_fields() must reflect the last tick without re-reading hardware.
local fields = rt2_engine.status_fields()
assert_eq(fields.mode, result.state)
assert_eq(fields.turbines[1].id, 'T1')

-- Die Leistungsmeldung an MASTER ist mitgeschrieben, nicht gelernt: der
-- hoechste Gesamtausstoss, der wirklich geflossen ist. Sie muss durch
-- status_fields() sichtbar sein -- MASTER teilt seinen Bedarf dagegen auf.
do
  assert_eq(fields.capacity_ready, true, 'eine Flotte im Zielband hat sich eingelernt')
  assert_eq(fields.capacity_max, 100, 'exactly the output that flowed -- no margin, no extrapolation')
  assert_eq(fields.capacity_total_turbines, 1)
  assert_eq(fields.capacity_at_target, 1)
  assert_true(fields.capacity_reason ~= nil, 'the capacity state must always carry a diagnostic reason')
end

-- Eine Flotte, die noch nichts liefert, meldet auch nichts -- und faehrt
-- deshalb voll, statt auf eine Vorgabe von 0 % zu warten.
do
  local idle_hardware = { T2 = { rpm = 0, energy = 0, coil_engaged = false, flow = 0, active = true } }
  local idle_ctx = {
    config = { turbines = { 'T2' }, reactors = { 'R1' } },
    CONFIG = { LOG_PREFIX = 'RT' },
    log = function() end,
    adapters = {
      turbine = {
        inspect = function(name) return idle_hardware[name] end,
        set_flow = function() return true end,
        set_coils = function() return true end,
        set_active = function() return true end,
      },
      reactor = fake_ctx.adapters.reactor,
    },
  }
  rt2_engine.init({})
  rt2_engine.tick(idle_ctx)
  local idle_fields = rt2_engine.status_fields()
  assert_eq(idle_fields.capacity_ready, false, 'waehrend des Einlernens meldet der Knoten nichts')
  assert_eq(idle_fields.capacity_max, 0)
  assert_eq(idle_fields.capacity_reason, 'LEARNING', 'und sagt, dass er einlernt')
  assert_eq(idle_fields.capacity_learning, true)
end

-- handle_command() must reach the underlying orchestrator and its
-- effects must show up on the next tick.
rt2_engine.init({})
rt2_engine.tick(fake_ctx)
local ack = rt2_engine.handle_command({ target = 'SCRAM' })
assert_true(ack.ok, 'SCRAM must be accepted through the engine facade')
advance(5000)
result = rt2_engine.tick(fake_ctx)
assert_eq(result.state, rt2_state.states.SAFE, 'a SCRAM issued through the engine facade must force SAFE on the next tick')
assert_eq(applied_rods, 100, 'SAFE must have written full rod insertion to the fake reactor adapter')

-- Regression: init() darf keinen Lernzustand mehr aufbauen und keine
-- Datei anlegen. Ein frischer Knoten ist im ersten Takt betriebsbereit --
-- vorher hing genau hier die Lernphase, aus der er im Feld nicht mehr
-- herauskam.
do
  rt2_engine.init({})
  assert_eq(rt2_engine.current_state(), rt2_state.states.INIT, 'a fresh engine starts in INIT')
  local first = rt2_engine.tick(fake_ctx)
  assert_true(first.state ~= rt2_state.states.INIT, 'and is operational after one tick')
  assert_eq(rt2_engine.CACHE_PATH, nil, 'there is no capacity cache file any more')
  assert_eq(rt2_engine.TUNING_PATH, nil, 'and no reactor tuning file')
  assert_eq(rt2_engine.TURBINE_MODEL_PATH, nil, 'and no turbine model file')
end

print('rt2_engine_test.lua: ok')
