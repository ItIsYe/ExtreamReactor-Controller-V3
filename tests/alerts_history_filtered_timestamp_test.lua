-- alerts:get_history_filtered(opts) filterte bislang auf entry.ts, ein Feld,
-- das History-Eintraege nie besitzen (nur ts_first/ts_last, plus
-- resolved_ts fuer einen Resolve-Snapshot -- siehe raise()/resolve()/
-- record_muted()). tonumber(entry.ts) or 0 war deshalb IMMER 0, wodurch
-- jeder since_ms-Filter (z.B. die "1h"/"24h"-Alarmhistorie im Master-UI)
-- ausnahmslos alles herausfilterte.

local now_ms = 1000000
_G.os = _G.os or {}
os.epoch = function() return now_ms end

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local alerts_lib = require('core.alerts')

local alerts = alerts_lib.new({ info_ttl_s = 0, history_size = 100 })

-- 1) "raise"-Eintrag: Ereigniszeit ist ts_first/ts_last zum Zeitpunkt des
--    ersten Auftretens.
now_ms = 1000000
alerts:raise({ code = 'A', title = 'Alpha', source = { node_id = 'N1' }, severity = 'WARN' })

-- 2) "resolve"-Eintrag: Ereigniszeit ist resolved_ts (wann es behoben wurde),
--    nicht ts_first/ts_last (wann es zuletzt aktualisiert wurde).
now_ms = 2000000
alerts:resolve('N1|unknown|' .. '|A')

-- 3) "muted"-Eintrag: Ereigniszeit ist ts_first/ts_last des Mute-Ereignisses.
now_ms = 3000000
alerts:record_muted({ code = 'B', title = 'Beta', source = { node_id = 'N2' }, severity = 'INFO', ts = now_ms })

now_ms = 4000000

-- "all" (kein Filter) muss weiterhin alle 3 Eintraege liefern.
local all = alerts:get_history_filtered({})
assert(#all == 3, 'expected 3 history entries total, got ' .. tostring(#all))

-- since_ms = 2500000 darf nur den Mute-Eintrag (ts=3000000) treffen --
-- NICHT den Resolve-Eintrag (resolved_ts=2000000, zu alt) und NICHT den
-- urspruenglichen Raise-Eintrag (ts_first=1000000, zu alt).
local recent = alerts:get_history_filtered({ since_ms = 2500000 })
assert(#recent == 1, 'expected exactly 1 entry after since_ms=2500000, got ' .. tostring(#recent))
assert(recent[1].title == 'Beta', 'expected the muted Beta entry, got ' .. tostring(recent[1].title))

-- since_ms = 1500000 muss den Resolve-Eintrag (resolved_ts=2000000) UND den
-- Mute-Eintrag treffen, aber nicht den urspruenglichen Raise-Eintrag.
local since_resolve = alerts:get_history_filtered({ since_ms = 1500000 })
assert(#since_resolve == 2, 'expected 2 entries after since_ms=1500000, got ' .. tostring(#since_resolve))

-- Ein since_ms weit in der Zukunft darf gar nichts mehr liefern (Regression
-- gegen den alten Bug waere hier "3", weil ts immer 0 gemeldet wurde und
-- 0 >= since_ms fuer ein zukuenftiges since_ms nie zutrifft -- das war
-- zufaellig richtig; der eigentliche Bug zeigte sich bei einem since_ms in
-- der Vergangenheit, das faelschlich ALLES ausgefiltert hat).
local far_future = alerts:get_history_filtered({ since_ms = 10000000 })
assert(#far_future == 0, 'expected 0 entries for a since_ms far in the future, got ' .. tostring(#far_future))

-- Der eigentliche Bug: ein since_ms in der Vergangenheit (z.B. "1h"-Fenster)
-- muss die kuerzlich aufgetretenen Eintraege finden, nicht alles wegfiltern.
local past_window = alerts:get_history_filtered({ since_ms = now_ms - 3600000 })
assert(#past_window == 3, 'a since_ms covering the whole history must not filter everything out, got ' .. tostring(#past_window))

print('alerts_history_filtered_timestamp_test.lua: ok')
