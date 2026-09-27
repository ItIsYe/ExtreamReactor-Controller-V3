package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- payload.snapshot war das MODUL, nicht eine Aufnahme.
--
-- status_snapshot.lua's build_status_payload() setzte `snapshot =
-- ctx.status_snapshot`. Unter diesem Namen reicht main.lua aber das Modul
-- status_snapshot.lua selbst herein -- eine Tabelle voller Funktionen. Ueber
-- das Modem bleibt davon nichts Brauchbares uebrig.
--
-- MASTER liest aus diesem Feld genau zwei Werte, in master/
-- startup_sequencer.lua:
--   * build_telemetry()   -- snapshot.avg_rpm, snapshot.max_temp
--   * should_emergency()  -- safety.should_scram{ temperature = snapshot.max_temp }
--
-- Das zweite ist ein Notausweg: MASTERs Temperatur-SCRAM ueber den
-- RT-Snapshot konnte nie ausloesen, weil dort nie eine Temperatur stand.
-- Aufgefallen beim Verdrahtungs-Durchgang nach dem v1-Ausbau; der Fehler ist
-- aelter als der Umbau.

local status_snapshot = require('nodes.rt.status_snapshot')
local safety = require('core.safety')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local REACTORS = { { id = 'r1', name = 'Reactor_7' }, { id = 'r2', name = 'Reactor_9' } }
local TURBINES = { { id = 't1', name = 'Turbine_1' }, { id = 't2', name = 'Turbine_2' } }
local TEMPS = { Reactor_7 = 812, Reactor_9 = 1190 }   -- der heissere gewinnt
local RPMS  = { Turbine_1 = 880, Turbine_2 = 920 }    -- Mittel 900

local ctx = {
  status_level = 'OK',
  current_state = 'AUTONOM',
  targets = { power = 0, power_percent = 0, rpm = 900, steam = 0 },
  build_health_payload = function() return { capabilities = {}, bindings = {} } end,
  devices = { registry_summary = {} },
  registry = {
    node_id = 'node-101',
    get_bound_devices = function(_, kind)
      return kind == 'reactor' and REACTORS or TURBINES
    end,
    get_summary = function() return {} end,
    get_devices_by_kind = function() return {} end,
    get_diagnostics = function() return {} end,
  },
  modules = {},
  log_prefix = 'RT',
  log = function() end,
  config = {},
  turbine_adapter = {
    inspect = function(name) return { rpm = RPMS[name], flow = 600, energy = 1000 } end,
  },
  reactor_adapter = {
    inspect = function(name)
      return { control_rod_level = 85, active = true, temperature = TEMPS[name], steam = 5000 }
    end,
  },
  get_available_steam = function() return 5000 end,
  get_device_caps = function() return {} end,
  read_turbine_rpm = function() return nil end,
  read_turbine_flow = function() return nil end,
}

local payload = status_snapshot.build_status_payload(ctx)

-- ── 1. Das Feld traegt Messwerte, keine Funktionen ───────────────────────

assert_true(type(payload.snapshot) == 'table', 'payload.snapshot fehlt')
for k, v in pairs(payload.snapshot) do
  assert_true(type(v) ~= 'function',
    'payload.snapshot enthaelt eine Funktion (' .. tostring(k) .. ') -- das war der Fehler')
end
assert_true(payload.snapshot.build_status_payload == nil,
  'payload.snapshot ist das Modul selbst, nicht eine Aufnahme')

assert_eq(payload.snapshot.max_temp, 1190, 'max_temp muss die HOECHSTE Temperatur sein')
assert_eq(payload.snapshot.avg_rpm, 900, 'avg_rpm muss das Mittel der Drehzahlen sein')
assert_eq(#payload.snapshot.turbines, 2, 'die Turbinenliste fehlt')

-- Die Temperatur haengt jetzt auch am Reaktor-Eintrag selbst.
local by_name = {}
for _, r in ipairs(payload.reactors) do by_name[r.name] = r end
assert_eq(by_name.Reactor_9.temperature, 1190, 'reactors[].temperature fehlt')

-- ── 2. MASTERs Temperatur-Notausweg loest damit wirklich aus ─────────────
--
-- Der eigentliche Nachweis: nicht "das Feld ist gefuellt", sondern "MASTER
-- kann daraus die Entscheidung treffen, um die es geht". should_emergency()
-- ist in master/startup_sequencer.lua lokal, also wird hier genau sein
-- Aufruf nachgebildet -- und per Quelltext festgehalten, dass er es auch
-- wirklich so aufruft. Bricht das auseinander, faellt es hier auf.

do
  local src = assert(io.open('xreactor/master/startup_sequencer.lua')):read('*a')
  assert_true(src:find('snapshot.max_temp', 1, true) ~= nil,
    'master/startup_sequencer.lua liest snapshot.max_temp nicht mehr -- dann'
      .. ' gehoert dieser Test angepasst, nicht das Feld entfernt')
  assert_true(src:find('snapshot.avg_rpm', 1, true) ~= nil,
    'master/startup_sequencer.lua liest snapshot.avg_rpm nicht mehr')
end

assert_true(safety.should_scram({
  temperature = payload.snapshot.max_temp, max_temperature = 950,
}), 'MASTER muss bei 1190 Grad aus dem Snapshot ausloesen -- genau das ging nie')
assert_eq(safety.should_scram({
  temperature = payload.snapshot.max_temp, max_temperature = 1300,
}), false, 'und unterhalb der Schwelle darf er nicht ausloesen')

print('rt_status_snapshot_master_fields_test.lua: ok')
