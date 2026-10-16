package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Seite MELDUNGEN auf einem AUX-Monitor, der ganze Weg: echte Seite
-- (master/ui/alarms.lua, neu gestaltet in 76730da5, v838), echte
-- Monitorverwaltung (AUX mit Stellvertreter), echter ui_controller, echter
-- Meldungsdienst mit echten Regeln.
--
-- Entstanden mit v835. Betreiber (2026-10-16): "Ich kann die Meldungen nicht
-- quittieren" -- und: "die Node anklicken, damit man weitere Infos
-- bekommt". Der eigentliche Grund damals: master/ui/multiview.lua zeichnete
-- auf AUX-Monitoren mit einem jedes Mal neuen Stellvertreter, gab hit_test()
-- aber den echten Monitor -- kein Tipp kam an.
--
-- Der Monitor ist 57x24 wie ein 3x2-Block-Monitor bei Textgroesse 0.5; die
-- Seite sieht davon 57x22 (zwei Zeilen fuer den Seitenwechsel) und nutzt
-- damit ihr kompaktes Layout: Liste, Antippen oeffnet die Einzelheiten,
-- Sperren/Vergessen/Alle quittieren hinter MEHR mit Rueckfrage.
--
-- Bewusst KEIN erzwungenes Neuzeichnen je Durchlauf (v837): ein Tipp aendert
-- das Modell nicht und muss selbst neu zeichnen lassen.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local now = 70000000
os.epoch = function() return now end
os.clock = function() return now / 1000 end

-- ── Bildschirm-Attrappe: was wo steht, je echtem Monitor ────────────────
-- Zwei Wege auf den Schirm: core/ui.lua schreibt ueber term.redirect()
-- (Statusleiste, Seitenwechsel), die Seite MELDUNGEN ganze Zeilen per
-- mon.blit(). Beides landet im selben Bild.
local screens = {}
local function owner(m) return (type(m) == 'table' and rawget(m, 'xr_session_mon')) or m end
local function screen_of(key) screens[key] = screens[key] or {}; return screens[key] end
local function put(key, x, y, text)
  local screen = screen_of(key)
  local row = screen[y] or string.rep(' ', 80)
  screen[y] = row:sub(1, x - 1) .. text .. row:sub(x + #text)
end
local cursor = { x = 1, y = 1 }
_G.term = {
  _current = nil,
  redirect = function(m) local old = _G.term._current; _G.term._current = m; return old end,
  setBackgroundColor = function() end, setTextColor = function() end,
  clear = function() screens[owner(_G.term._current) or 'term'] = {} end,
  setCursorPos = function(x, y) cursor.x, cursor.y = x, y end,
  write = function(text)
    text = tostring(text)
    put(owner(_G.term._current) or 'term', cursor.x, cursor.y, text)
    cursor.x = cursor.x + #text
  end,
  getSize = function() return 51, 19 end,
}
local function mk_mon(w, h)
  local mon = { cy = 1 }
  mon.getSize = function() return w, h end
  mon.setTextScale = function() end
  mon.isColor = function() return true end
  mon.setCursorPos = function(_, y) mon.cy = y end
  mon.blit = function(t, f, b)
    assert_true(#t == #f and #f == #b and #t <= w, 'blit passt auf den Monitor')
    put(mon, 1, mon.cy, t)
  end
  return mon
end
local function row_of(mon, y) return ((screens[mon] or {})[y] or ''):gsub('%s+$', '') end
local function find(mon, pattern)
  for y = 1, 40 do
    local x = row_of(mon, y):find(pattern, 1, true)
    if x then return x, y end
  end
  return nil
end
local function find_row(mon, pattern) return select(2, find(mon, pattern)) end

_G.fs = { exists = function() return false end, open = function() return nil end,
  getDir = function() return '' end, makeDir = function() end }
local utils = require('core.utils')
utils.log = function() end
utils.write_config = function() end
package.loaded['optional.speaker_alarm'] = { new = function() return { play = function() end } end }

local constants = require('shared.constants')
local health = require('core.health')
local multiview = require('master.ui.multiview')
local alarms = require('master.ui.alarms')
local alert_service = require('services.alert_service')
local controller_lib = require('master.ui_controller')

local nodes = {
  ['RT-1'] = { id = 'RT-1', role = constants.roles.RT_NODE, state = 'RUNNING', status = 'OK',
    health = { status = health.status.OK, reasons = {} }, rt = { problems = {} } },
  ['FUEL-1'] = { id = 'FUEL-1', role = constants.roles.FUEL_NODE, status = 'OK',
    health = { status = health.status.OK, reasons = {} } },
}
local service = alert_service.new({
  config = { alert_raise_after_s = 0, alert_clear_after_s = 0, alert_cooldown_s = 0, alert_clear_grace_s = 0,
    alert_eval_interval = 1 },
  nodes = nodes,
})
local function tick(n) for _ = 1, n or 1 do now = now + 1000; service:tick() end end
local function active(code)
  for _, a in ipairs(service:get_active()) do if a.code == code then return a end end
end

local monitors = {
  { id = 'M1', name = 'm1', mon = mk_mon(57, 24) }, { id = 'M2', name = 'm2', mon = mk_mon(57, 24) },
  { id = 'M3', name = 'm3', mon = mk_mon(57, 24) }, { id = 'M4', name = 'aux', mon = mk_mon(57, 24) },
}
local aux = monitors[4].mon

local controller
local view_manager = multiview.new({
  views = {
    overview = { render = function() end }, rt = { render = function() end }, energy = { render = function() end },
    alarms = { label = 'Meldungen', render = alarms.render, hit_test = alarms.hit_test, interval = 1.0 },
  },
  view_order = { 'overview', 'rt', 'energy', 'alarms' },
  on_action = function(action) return controller.handle_action(action) end,
})
controller = controller_lib.new({
  constants = constants, health = health, config = {}, nodes = nodes, alarms = {},
  comms = { get_diagnostics = function() return {} end },
  sequencer = { ramp_profile = 'NORMAL', state = 'IDLE', queue = {} },
  trends = { is_dirty = function() return false end, clear_dirty = function() end },
  trend_cache = { energy = {}, energy_arrow = '-' },
  state = { monitor_cache = { list = monitors }, last_draw = 0, power_target = 100, active_profile = 'BASELOAD',
    auto_profile = false, rt_global_off_hold = false },
  alert_service = service, view_manager = view_manager, calc = {}, log = function() end,
})

local function draw()
  now = now + 1100
  controller.draw()
end
draw()
local sessions = view_manager.sessions:get_sessions()
sessions[4].view_key = 'alarms'
sessions[4].dirty = true
-- Antippen ueber den ganzen Weg (multiview -> Seite -> Controller), dann
-- einmal zeichnen.
local function touch(pattern)
  local x, y = find(aux, pattern)
  assert_true(x, 'nicht auf dem Monitor: ' .. pattern)
  view_manager:handle_input('aux', x, y)
  draw()
end

-- ══ 1. Leer: alles in Ordnung ═══════════════════════════════════════════

draw()
assert_true(row_of(aux, 1):find('AUX:MELDUNGEN', 1, true) ~= nil, 'die Statusleiste nennt die Seite beim Namen: ' .. row_of(aux, 1))
assert_eq(find_row(aux, 'S:0 AN  W:0 AN  OFFEN:0'), 3, 'Zusammenfassung in Zeile 3')
assert_true(find_row(aux, 'Keine sichtbaren Meldungen') ~= nil, 'leer: Hinweis')
assert_eq(find_row(aux, '< ZURUECK'), 24, 'der Seitenwechsel bleibt in der letzten Zeile')

-- ══ 2. Eine Stoerung kommt: Zeile, Einzelheiten, Quittieren ═════════════

nodes['RT-1'].offline = true
tick(2)
draw()
local y = find_row(aux, 'RT-1  Node offline')
assert_true(y ~= nil and y >= 7, 'die Stoerung steht in der Liste')
assert_true(row_of(aux, y + 1):find('UTC | AN | OFFEN | x1', 1, true) ~= nil, 'darunter Zeit und Zustand: ' .. row_of(aux, y + 1))
assert_eq(find_row(aux, 'S:1 AN'), 3)

-- Antippen oeffnet die Einzelheiten -- quittiert aber nicht.
touch('RT-1  Node offline')
assert_true(find_row(aux, '< LISTE') ~= nil, 'Einzelheiten offen')
assert_true(find_row(aux, 'STOERUNG | RT-1') ~= nil, 'Klasse und Node')
assert_true(find_row(aux, 'RT-1 antwortet nicht') ~= nil, 'mit dem Text der Regel')
assert_true(not active('NODE_COMMS_DOWN').acknowledged, 'Antippen allein quittiert nicht')

touch('RT-1 QUITTIEREN')
assert_true(active('NODE_COMMS_DOWN').acknowledged, 'QUITTIEREN quittiert -- ueber den AUX-Monitor')
assert_true(find_row(aux, 'AN | QUITT. | x1') ~= nil, 'als quittiert markiert')
assert_true(find_row(aux, 'QUITTIERT') ~= nil, 'die Taste zeigt QUITTIERT')
-- Ein zweiter Tipp nimmt nichts zurueck.
touch('QUITTIERT')
assert_true(active('NODE_COMMS_DOWN').acknowledged, 'bleibt quittiert')
touch('< LISTE')
assert_true(find_row(aux, 'FILTER:ALLE') ~= nil, 'zurueck in der Liste')

-- ══ 3. RT meldet ein Problem: alle Zeilen in den Einzelheiten ═══════════

nodes['RT-1'].offline = false
nodes['RT-1'].rt.problems = { 'liefert 40% vom Soll (4.0k von 10.0k RF/t) seit 6 min', '- turbine_2: 300/900 U/min' }
tick(2)
draw()
touch('RT-1  RT meldet ein Problem')
assert_true(find_row(aux, 'liefert 40% vom Soll') ~= nil, 'erste Zeile der Node')
assert_true(find_row(aux, '- turbine_2: 300/900 U/min') ~= nil, 'auch die Turbinenzeile')
-- VERGESSEN gibt es nur fuer eine ausgefallene Node.
touch('MEHR ...')
assert_true(find_row(aux, 'MEHR / RT-1') ~= nil, 'Menue fuer die Auswahl')
assert_eq(find_row(aux, 'OFFLINE-NODE VERGESSEN'), nil, 'VERGESSEN fehlt fuer eine laufende Node')

-- ══ 4. Sperren und Entsperren, jeweils mit Rueckfrage ═══════════════════

touch('URSACHE 60 MIN SPERREN')
assert_true(find_row(aux, 'URSACHE 60 MIN SPERREN?') ~= nil and find_row(aux, 'Betrifft: RT-1') ~= nil, 'Rueckfrage')
assert_true(active('RT_PROBLEM') ~= nil, 'vor dem Bestaetigen ist nichts gesperrt')
touch('BESTAETIGEN')
assert_eq(active('RT_PROBLEM'), nil, 'gesperrt: aus der Liste')
tick(3)
draw()
assert_eq(find_row(aux, 'RT meldet ein Problem'), nil, 'und kommt waehrend der Sperre nicht wieder')
assert_true(find_row(aux, '1 URSACHE(N) GESPERRT') ~= nil, 'die Sperre steht im Kopf')
touch('MEHR / SPERREN')
touch('ALLE SPERREN AUFHEBEN (1)')
touch('BESTAETIGEN')
tick(2)
draw()
assert_true(find_row(aux, 'RT meldet ein Problem') ~= nil, 'entsperrt: steht wieder da')
nodes['RT-1'].rt.problems = {}
tick(2)
draw()

-- ══ 5. Node vergessen: nur fuer eine ausgefallene Node ══════════════════

nodes['FUEL-1'].offline = true
tick(2)
draw()
touch('FUEL-1  Node offline')
touch('MEHR ...')
touch('OFFLINE-NODE VERGESSEN')
assert_true(find_row(aux, 'Betrifft: FUEL-1') ~= nil, 'Rueckfrage nennt die Node')
local ampel_forgot
package.loaded['optional.master_ampel'] = { forget_node = function(id) ampel_forgot = id end }
touch('BESTAETIGEN')
package.loaded['optional.master_ampel'] = nil
assert_eq(nodes['FUEL-1'], nil, 'die ausgefallene Node ist vergessen')
assert_eq(ampel_forgot, 'FUEL-1', 'auch die MASTER-Ampel vergisst sie')
assert_eq(find_row(aux, 'FUEL-1'), nil, 'und ihre Meldung mit')

-- Eine laufende Node vergisst der Controller nicht.
assert_true(controller.handle_action({ type = 'alert_forget_node', node_id = 'RT-1' }))
assert_true(nodes['RT-1'] ~= nil, 'laufende Node bleibt')

-- ══ 6. Alle quittieren: Abbrechen tut nichts, Bestaetigen quittiert ═════

-- Eine neue Ursache: RT-1 kaeme innerhalb des Flatterschutz-Fensters schon
-- quittiert zurueck (v834).
nodes['RT-2'] = { id = 'RT-2', role = constants.roles.RT_NODE, state = 'RUNNING', status = 'OK', offline = true,
  health = { status = health.status.OK, reasons = {} }, rt = { problems = {} } }
tick(2)
draw()
local function unacked() local n = 0 for _, a in ipairs(service:get_active()) do if not a.acknowledged then n = n + 1 end end return n end
assert_true(unacked() > 0, 'etwas ist offen')
touch('MEHR / SPERREN')
touch('ALLE QUITTIEREN')
touch('ABBRECHEN')
assert_true(unacked() > 0, 'Abbrechen quittiert nichts')
touch('ALLE QUITTIEREN')
touch('BESTAETIGEN')
assert_eq(unacked(), 0, 'Bestaetigen quittiert alles')

-- ══ 7. Verlauf ══════════════════════════════════════════════════════════

assert_eq(find_row(aux, '< ZUR ANSICHT'), nil, 'nach dem Bestaetigen ist das Menue zu')
touch('VERLAUF')
assert_true(find_row(aux, 'KOMMT') ~= nil and find_row(aux, 'QUITT.') ~= nil, 'kommt/quittiert im Verlauf')
touch('LISTE')
assert_true(find_row(aux, 'FILTER:ALLE') ~= nil, 'zurueck zur Liste')

-- ══ 8. Zeile 2 gehoert der Seite (keine Ueberlagerung) ══════════════════

assert_true(active('NODE_COMMS_DOWN') ~= nil and active('NODE_COMMS_DOWN').active, 'eine Stoerung steht an')
assert_eq(row_of(aux, 2), '', 'auf der Meldungsseite schreibt multiview nicht in Zeile 2: ' .. row_of(aux, 2))

-- ══ 9. Alle anderen AUX-Views bekommen ihre Tipps ebenfalls ═════════════

do
  local zones = setmetatable({}, { __mode = 'k' })
  local got = {}
  local mv = multiview.new({
    views = {
      overview = { render = function() end }, rt = { render = function() end }, energy = { render = function() end },
      probe = {
        render = function(mon) zones[mon] = true end,
        hit_test = function(mon) if zones[mon] then return { type = 'probe_hit' } end end,
      },
    },
    view_order = { 'overview', 'rt', 'energy', 'probe' },
    on_action = function(a) got[#got + 1] = a.type; return true end,
  })
  mv:render(monitors, {})
  mv.sessions:get_sessions()[4].view_key = 'probe'
  mv.sessions:get_sessions()[4].dirty = true
  mv:render(monitors, {})
  mv:handle_input('aux', 10, 10)
  assert_eq(got[1], 'probe_hit', 'eine View mit Touch-Zonen je Monitor bekommt den Tipp auf dem AUX-Monitor')
end

print('master_meldungen_page_v835_test.lua: ok')
