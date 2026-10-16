-- Seite MELDUNGEN (master/ui/alarms.lua, v835): jeder Monitor hat seinen
-- eigenen Zustand (Auswahl, Seite, Reiter, Touch-Zonen). Frueher teilten sich
-- alle Monitore ein Paar Touch-Zonen auf Modulebene, und ein Tipp auf
-- Monitor A wurde gegen die Zonen von Monitor B geprueft. Dazu: auf
-- AUX-Monitoren zeichnet multiview.lua mit einem jedes Mal neuen
-- Stellvertreter -- der Zustand haengt am echten Monitor (xr_session_mon).

package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

package.loaded['core.ui'] = {
  getSize = function() return 50, 14 end,
  text = function() end,
  button = function() end,
}
package.loaded['shared.colors'] = { get = function(name) return name end }
package.loaded['master.ui.widgets'] = {
  fit = function(s, w) return tostring(s or ''):sub(1, w) end,
  pad = function(s, w) local t = tostring(s or ''):sub(1, w); return t .. string.rep(' ', w - #t) end,
}

local alarms = require('master.ui.alarms')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function alert(id, key, sev, title)
  return { id = id, key = key, severity = sev, title = title, ts_first = 1000, ts_came = 1000, active = true, count = 1,
    source = { node_id = 'N' } }
end
local mon_a, mon_b = {}, {}
local model_a = { active = { alert('ALERT-A', 'K-A', 'CRITICAL', 'A') }, counts = { CRITICAL = 1, UNACKED = 1 } }
local model_b = { active = { alert('ALERT-B1', 'K-B1', 'WARN', 'B1'), alert('ALERT-B2', 'K-B2', 'WARN', 'B2') },
  counts = { WARN = 2, UNACKED = 2 } }

alarms.render(mon_a, model_a)
alarms.render(mon_b, model_b)

-- Zeile 5 ist der erste Eintrag. Antippen waehlt aus -- es quittiert nicht.
assert_eq(alarms.hit_test(mon_a, 3, 5), nil, 'Antippen einer Zeile quittiert nicht')
alarms.hit_test(mon_b, 3, 6)
alarms.render(mon_a, model_a)
alarms.render(mon_b, model_b)

-- QUITT. sitzt unten links (Zeile 14), jeder Monitor quittiert SEINE Auswahl.
local hit_a = alarms.hit_test(mon_a, 2, 14)
assert(hit_a and hit_a.type == 'alert_ack', 'Monitor A: QUITT. muss quittieren')
assert_eq(hit_a.id, 'ALERT-A', 'Monitor A quittiert seine eigene Auswahl')
local hit_b = alarms.hit_test(mon_b, 2, 14)
assert(hit_b and hit_b.type == 'alert_ack', 'Monitor B: QUITT. muss quittieren')
assert_eq(hit_b.id, 'ALERT-B2', 'Monitor B quittiert seine eigene Auswahl')

-- Der AUX-Stellvertreter ist jedes Mal neu; die Auswahl bleibt.
local function proxy(real) return setmetatable({ xr_session_mon = real }, { __index = real }) end
alarms.render(proxy(mon_a), model_a)
local again = alarms.hit_test(proxy(mon_a), 2, 14)
assert(again and again.id == 'ALERT-A', 'die Auswahl ueberlebt den neuen Stellvertreter')

print('master_alarms_per_monitor_touch_isolation_test.lua: ok')
