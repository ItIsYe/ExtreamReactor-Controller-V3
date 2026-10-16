package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-16): "Ich kann die Meldungen nicht quittieren, oder
-- die kommen so schnell wieder, dass es nichts bringt." Dazu seine
-- Vorgaben: gegangene Stoerungen bis zur Quittierung stehen lassen -- oder
-- automatisch quittieren, wenn sie in einer Zeit X nicht wiederkommen;
-- Ampel blinkt, wenn nur noch etwas zu quittieren ist, und ist rot, solange
-- eine Stoerung akut ist.
--
-- Bis v833 hing die Quittung an der einzelnen Meldung: nach ~6 s ohne
-- Bedingung geloescht, beim Wiederkommen neu und unquittiert; ein zweiter
-- Tipp hob die Quittung auf; die Hupe lief auch nach der Quittung weiter.

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

local alerts_lib = require('core.alerts')
local MIN = 60000

local function events(store)
  local out = {}
  for i = #store.history, 1, -1 do out[#out + 1] = store.history[i].event end
  return table.concat(out, ',')
end

-- ══ 1. Eine Stoerung: kommt, geht, kommt wieder, wird quittiert ════════

do
  local store = alerts_lib.new({ auto_ack_s = 1800, reack_window_s = 1800 })
  local entry = { key = 'NODE_COMMS_DOWN|RT-1', code = 'NODE_COMMS_DOWN', severity = 'CRITICAL',
    source = { node_id = 'RT-1' }, title = 'Node offline', message = 'RT-1 antwortet nicht' }
  now = 1000000
  local first = store:raise(entry).alert
  local c = store:get_counts_by_severity()
  assert_eq(c.CRITICAL, 1, 'steht an')
  assert_eq(c.UNACKED_ACTIVE_CRITICAL, 1, 'unquittiert')

  now = now + 1000
  assert_eq(store:raise(entry).event, nil, 'eine Auffrischung ist kein Ereignis')

  now = now + 5000
  store:resolve(entry.key)
  c = store:get_counts_by_severity()
  assert_eq(c.CRITICAL, 0, 'steht nicht mehr an')
  assert_eq(c.GONE_UNACKED_CRITICAL, 1, 'gegangen, aber noch zu quittieren')
  assert_eq(#store:get_active(), 1, 'bleibt in der Liste')
  assert_eq(store:get_active()[1].active, false)

  now = now + 2000
  local again = store:raise(entry)
  assert_eq(again.event, 'again')
  assert_eq(again.alert.id, first.id, 'derselbe Eintrag -- nicht ein neuer')
  assert_eq(again.alert.count, 2, 'der Zaehler zaehlt mit')

  local ok = store:ack(first.id)
  assert_true(ok and first.acknowledged, 'quittiert')
  assert_true(not store:ack(first.id), 'ein zweiter Tipp nimmt nichts zurueck')
  assert_true(first.acknowledged, 'bleibt quittiert')
  assert_eq(store:get_counts_by_severity().UNACKED_ACTIVE_CRITICAL, 0, 'die Hupe hat keinen Grund mehr')
  assert_eq(store:get_counts_by_severity().CRITICAL, 1, 'steht aber weiter an (Ampel rot)')

  -- Quittiert und gegangen: aus der Liste.
  now = now + 1000
  store:resolve(entry.key)
  assert_eq(#store:get_active(), 0, 'quittiert + gegangen: erledigt')

  -- Flatterschutz: kommt sie innerhalb des Fensters wieder, kommt sie quittiert.
  now = now + 10 * MIN
  local back = store:raise(entry)
  assert_eq(back.event, 'again')
  assert_true(back.alert.acknowledged, 'kommt quittiert zurueck')
  assert_eq(back.alert.count, 3, 'und zaehlt weiter')
  assert_eq(store:get_counts_by_severity().UNACKED_ACTIVE_CRITICAL, 0, 'keine Hupe beim Flattern')

  -- Ausserhalb des Fensters: wieder neu -- auch ohne tick() dazwischen.
  now = now + 1000; store:resolve(entry.key)
  now = now + 31 * MIN
  local fresh = store:raise(entry)
  assert_eq(fresh.event, 'raise', 'nach dem Fenster ein neuer Fall')
  assert_true(not fresh.alert.acknowledged)
  assert_eq(fresh.alert.count, 1)

  assert_eq(events(store), 'raise,clear,again,ack,clear,again,clear,raise', 'Verlauf: nur Ereignisse')

  -- tick() raeumt den Flatterschutz nach dem Fenster auf.
  now = now + 1000; store:ack(fresh.alert.id); store:resolve(entry.key)
  assert_true(store.recent[entry.key] ~= nil)
  store:tick(now + 30 * MIN + 1)
  assert_eq(store.recent[entry.key], nil, 'nach dem Fenster vergessen')
end

-- ══ 2. Automatisch quittieren, wenn sie in X nicht wiederkommt ═════════

do
  local store = alerts_lib.new({ auto_ack_s = 30 * 60, reack_window_s = 30 * 60 })
  local entry = { key = 'RT_SAFE_MODE|RT-1', code = 'RT_SAFE_MODE', severity = 'CRITICAL', source = { node_id = 'RT-1' } }
  now = 5000000
  store:raise(entry)
  now = now + 1000; store:resolve(entry.key)
  local gone_at = now
  now = gone_at + 30 * MIN - 1
  local _, auto = store:tick(now)
  assert_eq(#auto, 0, 'vor Ablauf nichts')
  assert_eq(#store:get_active(), 1)
  now = gone_at + 30 * MIN
  _, auto = store:tick(now)
  assert_eq(#auto, 1, 'nach 30 min ohne Wiederkehr automatisch quittiert')
  assert_true(auto[1].ack_auto, 'als automatisch markiert')
  assert_eq(#store:get_active(), 0, 'und aus der Liste')
  assert_eq(store.history[1].event, 'auto_ack')

  -- Kommt sie dazwischen wieder, laeuft die Frist neu.
  store = alerts_lib.new({ auto_ack_s = 30 * 60 })
  now = 9000000
  store:raise(entry); now = now + 1000; store:resolve(entry.key)
  now = now + 20 * MIN; store:raise(entry); now = now + 1000; store:resolve(entry.key)
  gone_at = now
  now = gone_at + 25 * MIN
  local _, a2 = store:tick(now)
  assert_eq(#a2, 0, 'die Frist zaehlt ab dem letzten Gehen')
end

-- ══ 3. Warnungen gehen von selbst; schlimmer heisst neu quittieren ═════

do
  local store = alerts_lib.new({})
  local warn = { key = 'NODE_COMMS_DOWN|REPROC-1', code = 'NODE_COMMS_DOWN', severity = 'WARN', source = { node_id = 'REPROC-1' } }
  now = 20000000
  store:raise(warn)
  now = now + 1000; store:resolve(warn.key)
  assert_eq(#store:get_active(), 0, 'eine Warnung bleibt nicht stehen')

  local e = { key = 'MATRIX_MISSING|E1', code = 'MATRIX_MISSING', severity = 'WARN', source = { node_id = 'E1' } }
  local a = store:raise(e).alert
  store:ack(a.id)
  e.severity = 'CRITICAL'
  now = now + 1000
  local r = store:raise(e)
  assert_eq(r.event, 'severity')
  assert_true(not r.alert.acknowledged, 'schlimmer geworden: die alte Quittung gilt nicht')
  -- Zurueck auf WARN: die Quittung kommt nicht von allein wieder.
  e.severity = 'WARN'
  assert_true(not store:raise(e).alert.acknowledged)

  -- Dasselbe ueber den Flatterschutz: quittierte Warnung geht, kommt
  -- innerhalb des Fensters als Stoerung wieder -- dann unquittiert.
  local f = { key = 'X|E2', code = 'X', severity = 'WARN', source = { node_id = 'E2' } }
  store:ack(store:raise(f).alert.id)
  now = now + 1000; store:resolve(f.key)
  f.severity = 'CRITICAL'
  now = now + 1000
  local back = store:raise(f)
  assert_eq(back.event, 'again')
  assert_true(not back.alert.acknowledged, 'als Stoerung zurueck: neu zu quittieren')
end

-- ══ 4. Alle quittieren, Node vergessen, Reihenfolge ═════════════════════

do
  local store = alerts_lib.new({})
  now = 30000000
  local function raise(key, sev, node) return store:raise({ key = key, code = key, severity = sev, source = { node_id = node } }).alert end
  local w = raise('W|N1', 'WARN', 'N1')
  local c1 = raise('C|N1', 'CRITICAL', 'N1')
  local c2 = raise('C|N2', 'CRITICAL', 'N2')
  now = now + 1000; store:resolve('C|N2')
  local order = {}
  for _, a in ipairs(store:get_active()) do order[#order + 1] = a.key end
  assert_eq(table.concat(order, ','), 'C|N1,C|N2,W|N1', 'Stoerungen zuerst, anstehend vor gegangen')
  store:ack(c1.id)
  order = {}
  for _, a in ipairs(store:get_active()) do order[#order + 1] = a.key end
  assert_eq(table.concat(order, ','), 'C|N2,C|N1,W|N1', 'Unquittiertes vor Quittiertem')

  local changed = store:ack_all()
  assert_eq(#changed, 2, 'die zwei noch offenen')
  assert_eq(#store:get_active(), 2, 'die gegangene Stoerung ist mit dem Quittieren erledigt')
  local _ = w; _ = c2

  now = now + 1000; store:resolve('W|N1')
  assert_true(store.recent['W|N1'] ~= nil and store.recent['C|N2'] ~= nil, 'beide im Flatterschutz')
  store:forget_node('N1')
  assert_eq(#store:get_active(), 0, 'alles zu N1 vergessen')
  assert_eq(store.recent['W|N1'], nil, 'auch fuer den Flatterschutz')
  assert_true(store.recent['C|N2'] ~= nil, 'N2 bleibt')
end

-- ══ 5. Dienst + Regeln + Hupe: der Ablauf an der Anlage ════════════════

local constants = require('shared.constants')
local health = require('core.health')

local plays = {}
package.loaded['optional.speaker_alarm'] = {
  new = function() return { play = function(kind) plays[#plays + 1] = kind end } end,
}
package.loaded['services.alert_service'] = nil
local alert_service_lib = require('services.alert_service')

local nodes = {
  ['RT-1'] = { id = 'RT-1', role = constants.roles.RT_NODE, state = 'RUNNING', rt = { problems = {} },
    health = { status = health.status.OK, reasons = {} } },
  ['REPROC-1'] = { id = 'REPROC-1', role = constants.roles.REPROCESSOR_NODE,
    health = { status = health.status.OK, reasons = {} } },
}
local service = alert_service_lib.new({
  config = { alert_raise_after_s = 0, alert_clear_after_s = 0, alert_cooldown_s = 0, alert_clear_grace_s = 0,
    alert_eval_interval = 1, alarm_auto_ack_min = 30, alarm_reack_window_min = 30, alert_log_muted_events = true },
  nodes = nodes,
})
local function tick(seconds)
  for _ = 1, seconds do now = now + 1000; service:tick() end
end
local function count(kind)
  local n = 0
  for _, k in ipairs(plays) do if k == kind then n = n + 1 end end
  return n
end

now = 50000000
tick(3)
assert_eq(#plays, 0, 'Ruhe im Normalbetrieb')

nodes['RT-1'].offline = true
tick(3)
local entry = service:get_active()[1]
assert_eq(entry.code, 'NODE_COMMS_DOWN')
assert_eq(entry.severity, 'CRITICAL')
assert_true(count('alarm') >= 2, 'unquittiert: die Hupe laeuft')
assert_eq(count('node_offline'), 1, 'der Offline-Ton einmal je Auftreten')

service:ack(entry.id)
local before = count('alarm')
tick(5)
assert_eq(count('alarm'), before, 'quittiert: die Hupe ist aus')
assert_eq(service:get_counts().CRITICAL, 1, 'die Stoerung steht weiter an')

nodes['RT-1'].offline = false
tick(2)
assert_eq(#service:get_active(), 0, 'quittiert + wieder da: erledigt')
assert_eq(count('clear'), 1, 'Entwarnung einmal')

-- Flattert die Node danach, kommt die Stoerung quittiert -- keine Hupe.
before = count('alarm')
local before_offline = count('node_offline')
for _ = 1, 3 do
  nodes['RT-1'].offline = true; tick(2)
  nodes['RT-1'].offline = false; tick(2)
end
assert_eq(count('alarm'), before, 'Flattern innerhalb des Fensters hupt nicht')
assert_eq(count('node_offline'), before_offline, 'und spielt keinen Offline-Ton')

-- Faellt sie aus und kommt zurueck, ohne dass jemand quittiert: der Eintrag
-- bleibt stehen -- und nach 30 min ohne Wiederkehr wird er automatisch
-- quittiert.
now = now + 31 * MIN
service:tick()
nodes['RT-1'].offline = true; tick(2)
nodes['RT-1'].offline = false; tick(2)
local list = service:get_active()
assert_eq(#list, 1, 'gegangen, nicht quittiert: bleibt stehen')
assert_eq(list[1].active, false)
assert_eq(service:get_counts().GONE_UNACKED_CRITICAL, 1)
assert_eq(#service:get_top_critical(3), 0, 'die Uebersicht zeigt nur anstehende Stoerungen')
local payload = require('master.housekeeping').build_master_alert_payload(service, {})
assert_eq(next(payload.alerts.by_node), nil, 'an die Nodes geht nur Anstehendes')
now = now + 30 * MIN
service:tick()
assert_eq(#service:get_active(), 0, 'nach 30 min automatisch quittiert')

-- Gesperrte Meldungen fluten den Verlauf nicht mehr.
service:mute_node('REPROC-1', 60)
local hist_before = #service:get_history()
nodes['REPROC-1'].offline = true
tick(20)
local muted = 0
for i = 1, #service:get_history() - hist_before do
  if service:get_history()[i].event == 'muted' then muted = muted + 1 end
end
assert_eq(muted, 1, 'eine gesperrte Meldung steht einmal im Verlauf, nicht alle paar Sekunden')
nodes['REPROC-1'].offline = false
tick(2)

-- Node vergessen: Eintraege und Regelzustand weg.
nodes['RT-1'].offline = true; tick(2)
assert_eq(#service:get_active(), 1)
service:forget_node('RT-1')
assert_eq(#service:get_active(), 0, 'vergessen')
for key in pairs(service.rules.state) do
  assert_true(not key:find('RT-1', 1, true), 'auch der Regelzustand: ' .. key)
end

-- ══ 6. MASTER-Ampel: rot, solange akut; blinkt, wenn nur zu quittieren ═

package.loaded['optional.master_ampel'] = nil
local ampel = require('optional.master_ampel')
local painted = {}
local mon = {
  getTextScale = function() return 1 end, setTextScale = function() end,
  getSize = function() return 7, 5 end,
  setBackgroundColor = function(c) painted[#painted + 1] = c end, clear = function() end,
}
_G.peripheral = {
  getNames = function() return { 'ampel' } end, getType = function() return 'monitor' end,
  wrap = function() return mon end, isPresent = function() return true end,
}
local runtime = {
  state = { rt_global_off_hold = false, power_target = 100, active_profile = 'BASELOAD', nodes = {} },
  refs = { alert_service = service },
}
local acon = { roles = constants.roles, status_levels = constants.status_levels }

local key = { key = 'RT_SAFE_MODE|RT-2', code = 'RT_SAFE_MODE', severity = 'CRITICAL', source = { node_id = 'RT-2' } }
service.alerts:raise(key)
assert_eq(ampel.determine_color(runtime, acon), 'red', 'akut: rot (auch unquittiert nicht blinkend)')
service.alerts:resolve(key.key)
assert_eq(ampel.determine_color(runtime, acon), 'red_blink', 'nur noch zu quittieren: blinkt')

for s = 1, 4 do
  clock = 100 + s
  ampel.update(runtime, acon)
end
assert_eq(table.concat(painted, ','), table.concat({ colors.black, colors.red, colors.black, colors.red }, ','),
  'im Sekundentakt rot/aus')

service:ack_all()
assert_eq(ampel.determine_color(runtime, acon), 'green', 'quittiert: gruen')

-- Eine quittierte, anstehende Stoerung bleibt rot.
local a = service.alerts:raise(key).alert
service:ack(a.id)
assert_eq(ampel.determine_color(runtime, acon), 'red', 'quittiert, steht aber an: rot')

-- Die Ampel wird jede Sekunde aufgerufen -- sonst blinkte sie nicht.
do
  local f = assert(io.open('xreactor/master/loop.lua', 'r'))
  local src = f:read('*a'); f:close()
  assert_true(src:find('runtime.state.last_master_ampel_check >= 1000', 1, true) ~= nil, 'Ampel im Sekundentakt')
end

print('alarm_lifecycle_v834_test.lua: ok')
