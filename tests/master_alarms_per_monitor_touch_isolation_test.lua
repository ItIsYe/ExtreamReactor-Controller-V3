-- Seite MELDUNGEN (master/ui/alarms.lua, neu gestaltet in 76730da5, v838):
-- jeder Monitor hat seinen eigenen Zustand (Auswahl, Ansicht, Filter,
-- Touch-Zonen). Frueher teilten sich alle Monitore ein Paar Touch-Zonen auf
-- Modulebene, und ein Tipp auf Monitor A wurde gegen die Zonen von Monitor B
-- geprueft. Dazu: auf AUX-Monitoren zeichnet multiview.lua mit einem jedes
-- Mal neuen Stellvertreter -- der Zustand haengt am echten Monitor
-- (xr_session_mon).
--
-- Die Seite schreibt ganze Zeilen per mon.blit(). CC:Tweaked bricht ab, wenn
-- Text, Vorder- und Hintergrund verschieden lang sind; die Attrappe prueft
-- das bei jedem Aufruf, in allen Layouts (schmal, AUX 3x2, AUX 4x3, mittel,
-- breit).

package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual), 2)
  end
end
local function assert_true(v, message) if not v then error(message or 'assert_true failed', 2) end end

local alarms = require('master.ui.alarms')

-- ── Monitor-Attrappe mit blit ───────────────────────────────────────────
local function mk_mon(w, h)
  local mon = { rows = {}, cy = 1 }
  mon.getSize = function() return w, h end
  mon.isColor = function() return true end
  mon.setCursorPos = function(_, y) mon.cy = y end
  mon.blit = function(t, f, b)
    assert_true(#t == #f and #f == #b, 'blit: Text, Vorder- und Hintergrund gleich lang')
    assert_true(#t <= w, 'blit: nicht breiter als der Monitor')
    assert_true(mon.cy >= 1 and mon.cy <= h, 'blit: Zeile auf dem Monitor')
    mon.rows[mon.cy] = t
  end
  return mon
end
local function proxy(real) return setmetatable({ xr_session_mon = real }, { __index = real }) end
local function find(mon, pattern)
  for y = 1, 60 do
    local row = mon.rows[y]
    local x = row and row:find(pattern, 1, true)
    if x then return x, y end
  end
end
local function tap(mon, pattern, target)
  local x, y = find(mon, pattern)
  assert_true(x, 'nicht auf dem Monitor: ' .. pattern)
  return alarms.hit_test(target or mon, x, y)
end

local function alert(id, key, sev, title, extra)
  local a = { id = id, key = key, code = 'TEST', severity = sev, title = title, ts_first = 1000, ts_came = 1000,
    active = true, count = 1, source = { node_id = key } }
  for k, v in pairs(extra or {}) do a[k] = v end
  return a
end

-- ══ 1. Zwei Monitore, zwei Auswahlen ════════════════════════════════════

local mon_a, mon_b = mk_mon(57, 22), mk_mon(57, 22)
local model_a = { active = { alert('ALERT-A', 'NODE-A', 'CRITICAL', 'Ausfall A') }, counts = { CRITICAL = 1, UNACKED = 1 } }
local model_b = { active = { alert('ALERT-B1', 'NODE-B1', 'WARN', 'Warnung B1'), alert('ALERT-B2', 'NODE-B2', 'WARN', 'Warnung B2') },
  counts = { WARN = 2, UNACKED = 2 } }
local function draw() alarms.render(mon_a, model_a); alarms.render(mon_b, model_b) end
draw()

assert_eq(tap(mon_a, 'NODE-A  Ausfall A'), nil, 'Antippen einer Zeile quittiert nicht')
assert_eq(tap(mon_b, 'NODE-B2  Warnung B2'), nil, 'Antippen einer Zeile quittiert nicht')
draw()
assert_true(find(mon_a, '< LISTE') and find(mon_a, 'Ausfall A'), 'Monitor A zeigt die Einzelheiten von A')
assert_true(find(mon_b, '< LISTE') and find(mon_b, 'Warnung B2') and not find(mon_b, 'Warnung B1'),
  'Monitor B zeigt die Einzelheiten von B2')

local hit_a = tap(mon_a, 'NODE-A QUITTIEREN')
assert_true(hit_a and hit_a.type == 'alert_ack', 'Monitor A: QUITTIEREN quittiert')
assert_eq(hit_a.id, 'ALERT-A', 'Monitor A quittiert seine eigene Auswahl')
local hit_b = tap(mon_b, 'NODE-B2 QUITTIEREN')
assert_true(hit_b and hit_b.type == 'alert_ack', 'Monitor B: QUITTIEREN quittiert')
assert_eq(hit_b.id, 'ALERT-B2', 'Monitor B quittiert seine eigene Auswahl')

-- Ein zweiter Tipp vor dem Neuzeichnen trifft keine alte Zone.
assert_eq(tap(mon_a, 'NODE-A QUITTIEREN'), nil, 'zweiter Tipp vor dem Neuzeichnen wirkt nicht')

-- ══ 2. Der AUX-Stellvertreter ist jedes Mal neu; die Auswahl bleibt ════

alarms.render(proxy(mon_a), model_a)
local again = tap(mon_a, 'NODE-A QUITTIEREN', proxy(mon_a))
assert_true(again and again.id == 'ALERT-A', 'die Auswahl ueberlebt den neuen Stellvertreter')

-- ══ 3. Eine veraltete Taste trifft keine andere Meldung ═════════════════

alarms.render(mon_a, model_a)
local qx, qy = find(mon_a, 'NODE-A QUITTIEREN')
model_a.active[1] = alert('ALERT-A2', 'NODE-A', 'CRITICAL', 'Ausfall A')
assert_eq(alarms.hit_test(mon_a, qx, qy), nil, 'gleiche Ursache, neue Meldung: die alte Taste quittiert sie nicht')
alarms.render(mon_a, model_a)
local fresh = tap(mon_a, 'NODE-A QUITTIEREN')
assert_true(fresh and fresh.id == 'ALERT-A2', 'nach dem Neuzeichnen quittiert die Taste die neue Meldung')

-- ══ 4. Filter je Monitor ════════════════════════════════════════════════

alarms.render(mon_a, model_a); tap(mon_a, '< LISTE')
alarms.render(mon_b, model_b); tap(mon_b, '< LISTE')
draw()
tap(mon_b, 'FILTER:ALLE')
draw()
assert_true(find(mon_b, 'FILTER:STOER.') and find(mon_b, 'Keine Treffer'), 'Monitor B filtert auf Stoerungen')
assert_true(find(mon_a, 'FILTER:ALLE') and find(mon_a, 'Ausfall A'), 'Monitor A filtert weiter nichts')

-- ══ 5. VERGESSEN nur fuer eine Node, die gerade ausgefallen ist ════════

do
  local mon = mk_mon(57, 22)
  local function offer(a)
    local model = { active = { a }, counts = { CRITICAL = 1, UNACKED = 1 } }
    alarms.render(mon, model); tap(mon, a.key .. '  ' .. a.title)
    alarms.render(mon, model); tap(mon, 'MEHR ...')
    alarms.render(mon, model)
    local shown = find(mon, 'OFFLINE-NODE VERGESSEN') ~= nil
    tap(mon, '< ZUR ANSICHT'); alarms.render(mon, model); tap(mon, '< LISTE')
    return shown
  end
  assert_true(offer(alert('D-1', 'RT-7', 'CRITICAL', 'Node offline', { code = 'NODE_COMMS_DOWN' })),
    'ausgefallene Node: VERGESSEN wird angeboten')
  assert_true(not offer(alert('D-2', 'RT-8', 'CRITICAL', 'Node offline', { code = 'NODE_COMMS_DOWN', active = false })),
    'wieder da (WEG, noch zu quittieren): kein VERGESSEN')
  assert_true(not offer(alert('D-3', 'RT-6', 'CRITICAL', 'RT meldet ein Problem', { code = 'RT_PROBLEM' })),
    'andere Ursache: kein VERGESSEN')
end

-- ══ 6. Alle Layouts: auswaehlen und quittieren, blit passt ══════════════

for _, size in ipairs({ { 36, 22 }, { 57, 22 }, { 52, 23 }, { 61, 31 }, { 100, 28 } }) do
  local w, h = size[1], size[2]
  local label = w .. 'x' .. h
  local mon = mk_mon(w, h)
  local model = { active = { alert('X-1', 'RT-9', 'CRITICAL', 'Node offline',
    { code = 'NODE_COMMS_DOWN', details = { lines = { 'Zeile eins', 'Zeile zwei' } } }) },
    counts = { CRITICAL = 1, UNACKED = 1 } }
  alarms.render(mon, model)
  for y = 2, h do assert_eq(#(mon.rows[y] or ''), w, label .. ': Zeile ' .. y .. ' ganz geschrieben') end
  assert_eq(mon.rows[1], nil, label .. ': Zeile 1 gehoert der Statusleiste')
  assert_eq(tap(mon, 'RT-9  Node offline'), nil, label .. ': Antippen quittiert nicht')
  alarms.render(mon, model)
  local hit = tap(mon, 'RT-9 QUITTIEREN')
  assert_true(hit and hit.type == 'alert_ack' and hit.id == 'X-1', label .. ': QUITTIEREN quittiert die Auswahl')
end

-- Zu kleiner Monitor: Hinweis statt einer zerbrochenen Seite.
local tiny = mk_mon(29, 13)
alarms.render(tiny, { active = {} })
assert_true(find(tiny, 'Monitor zu klein'), 'zu klein: Hinweis')

print('master_alarms_per_monitor_touch_isolation_test.lua: ok')
