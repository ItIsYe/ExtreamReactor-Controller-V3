package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Meldungen mit den ECHTEN Standardwerten des MASTER (master/config.lua
-- + master/context.lua normalize_config) -- nicht mit den Abkuerzungen der
-- anderen Tests (Entprellung 0, Schonfrist 0).
--
-- Bis v836 ging keine Meldung jemals: die Regeln melden "ist weg" genau
-- einmal, services/alert_service.lua's _clear_alert() merkte sich beim
-- ersten Aufruf nur den Zeitpunkt (Schonfrist alert_clear_grace_s, Standard
-- 3 s) und wurde nie wieder gefragt. Die Tests setzten die Schonfrist auf 0
-- und sahen das nicht. Folge an der Anlage: keine Stoerung wurde zu "WEG",
-- keine Warnung verschwand, die automatische Quittung griff nie, und die
-- MASTER-Ampel blieb nach jedem Ausfall rot -- auch nach dem Quittieren.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local now = 1000000
os.epoch = function() return now end
local clock = 0
os.clock = function() return clock end
_G.colors = { green = 1, yellow = 2, orange = 4, red = 8, gray = 16, black = 32768 }
_G.fs = { exists = function() return false end, open = function() return nil end,
  getDir = function() return '' end, makeDir = function() end }
local utils = require('core.utils')
utils.log = function() end
utils.write_config = function() end
local plays = {}
package.loaded['optional.speaker_alarm'] = {
  new = function() return { play = function(kind) plays[#plays + 1] = kind end } end,
}

local constants = require('shared.constants')
local health = require('core.health')

local config = dofile('xreactor/master/config.lua')
require('master.context').normalize_config(config)
assert_eq(config.alert_clear_grace_s, nil, 'die Schonfrist ist nicht gesetzt -- es gilt der eingebaute Wert (3 s)')
assert_true((config.alert_raise_after_s or 0) > 0 and (config.alert_clear_after_s or 0) > 0, 'echte Entprellung')

local nodes = {
  ['RT-1'] = { id = 'RT-1', role = constants.roles.RT_NODE, state = 'RUNNING', capacity_ready = true, rt = { problems = {} },
    health = { status = health.status.OK, reasons = {} } },
  ['REPROC-1'] = { id = 'REPROC-1', role = constants.roles.REPROCESSOR_NODE,
    health = { status = health.status.OK, reasons = {} } },
  ['ENERGY-1'] = { id = 'ENERGY-1', role = constants.roles.ENERGY_NODE, stored = 500, capacity = 1000,
    health = { status = health.status.OK, reasons = {} } },
}
package.loaded['services.alert_service'] = nil
local service = require('services.alert_service').new({ config = config, nodes = nodes })
local function tick(seconds) for _ = 1, seconds do now = now + 1000; service:tick() end end
local function entry(code)
  for _, a in ipairs(service:get_active()) do if a.code == code then return a end end
  return nil
end
local function horn() local n = 0 for _, k in ipairs(plays) do if k == 'alarm' then n = n + 1 end end return n end
local MIN = 60

-- ══ 1. Eine Warnung geht von selbst ═════════════════════════════════════

nodes['REPROC-1'].offline = true
tick(5)
assert_true(entry('NODE_COMMS_DOWN') ~= nil, 'REPROC offline: Warnung')
nodes['REPROC-1'].offline = false
tick(10)
assert_eq(entry('NODE_COMMS_DOWN'), nil, 'wieder da: nach Entprellung und Schonfrist weg -- das ging bis v836 nie')

-- ══ 2. Eine Stoerung wird WEG, blinkt, wird automatisch quittiert ═══════

package.loaded['optional.master_ampel'] = nil
local ampel = require('optional.master_ampel')
local runtime = { state = { rt_global_off_hold = false, power_target = 100, active_profile = 'BASELOAD', nodes = nodes },
  refs = { alert_service = service } }

nodes['RT-1'].offline = true
tick(5)
local a = entry('NODE_COMMS_DOWN')
assert_true(a and a.severity == 'CRITICAL' and a.active, 'RT offline: Stoerung steht an')
assert_eq(ampel.determine_color(runtime, constants), 'red', 'Ampel rot')
nodes['RT-1'].offline = false
tick(10)
a = entry('NODE_COMMS_DOWN')
assert_true(a ~= nil and a.active == false, 'wieder da: WEG, aber noch zu quittieren')
assert_eq(ampel.determine_color(runtime, constants), 'red_blink', 'Ampel blinkt')
local horn_after_gone = horn()
tick(60)
assert_eq(horn(), horn_after_gone, 'eine gegangene Stoerung hupt nicht')
tick(28 * MIN)
assert_true(entry('NODE_COMMS_DOWN') ~= nil, 'vor Ablauf der 30 min steht sie noch')
tick(2 * MIN)
assert_eq(entry('NODE_COMMS_DOWN'), nil, 'nach 30 min ohne Wiederkehr automatisch quittiert')
assert_eq(ampel.determine_color(runtime, constants), 'green', 'Ampel wieder gruen')

-- ══ 3. Quittiert und gegangen: erledigt; Flattern hupt nicht ════════════

nodes['RT-1'].offline = true
tick(5)
service:ack(entry('NODE_COMMS_DOWN').id)
assert_eq(ampel.determine_color(runtime, constants), 'red', 'quittiert, steht an: weiter rot')
nodes['RT-1'].offline = false
tick(10)
assert_eq(entry('NODE_COMMS_DOWN'), nil, 'quittiert und gegangen: aus der Liste')
assert_eq(ampel.determine_color(runtime, constants), 'green', 'und gruen -- bis v836 blieb sie rot')
local horn_before = horn()
for _ = 1, 3 do
  nodes['RT-1'].offline = true; tick(6)
  nodes['RT-1'].offline = false; tick(10)
end
assert_eq(horn(), horn_before, 'Flattern innerhalb des Fensters hupt nicht')
assert_eq(entry('NODE_COMMS_DOWN'), nil, 'und laesst nichts stehen')

-- ══ 4. Energie: kommt bei 10 %, geht ab 15 % ════════════════════════════

nodes['ENERGY-1'].stored = 90
tick(5)
assert_true(entry('ENERGY_LOW') ~= nil, '9 %: Warnung')
nodes['ENERGY-1'].stored = 140
tick(15)
assert_true(entry('ENERGY_LOW') ~= nil, '14 %: bleibt')
nodes['ENERGY-1'].stored = 160
tick(10)
assert_eq(entry('ENERGY_LOW'), nil, '16 %: geht')

-- ══ 5. Der direkte Weg aus master/runtime_ops_rt.lua (Rueckkehr) ════════

do
  -- check_timeouts() ruft beim Wiederverbinden _clear_alert() genau einmal.
  service.alerts:raise({ key = 'DIRECT|X', code = 'DIRECT', severity = 'WARN', source = { node_id = 'X' } })
  service:_clear_alert('DIRECT|X', now)
  assert_true(service.alerts.active_by_key['DIRECT|X'] ~= nil, 'erst die Schonfrist abwarten')
  tick(5)
  assert_eq(service.alerts.active_by_key['DIRECT|X'], nil, 'dann aufgeloest, ohne zweiten Aufruf')
end

print('alarm_defaults_v837_test.lua: ok')
