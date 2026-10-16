package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Seite MELDUNGEN (v835). Betreiber (2026-10-16): "Ich kann die Meldungen
-- nicht quittieren" -- und: "die Node anklicken, damit man weitere Infos
-- bekommt".
--
-- Der eigentliche Grund, warum auf den AUX-Monitoren kein Tipp ankam:
-- master/ui/multiview.lua zeichnete dort mit einem jedes Mal neuen
-- Stellvertreter-Objekt, gab hit_test() aber den echten Monitor. Jede View,
-- die ihre Touch-Zonen je Monitor fuehrt, suchte sie unter dem falschen
-- Schluessel -- "Logs" und "Alerts" nahmen keinen einzigen Tipp an.
--
-- Dieser Test laeuft deshalb den ganzen Weg: echte Seite, echte
-- Monitorverwaltung (AUX mit Stellvertreter), echter ui_controller, echter
-- Meldungsdienst mit echten Regeln.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local now = 70000000
os.epoch = function() return now end
os.clock = function() return now / 1000 end

-- ── Bildschirm-Attrappe: was wo steht, je echtem Monitor ────────────────
local screens = {}
local function owner(m) return (type(m) == 'table' and rawget(m, 'xr_session_mon')) or m end
local cursor = { x = 1, y = 1 }
_G.term = {
  _current = nil,
  redirect = function(m) local old = _G.term._current; _G.term._current = m; return old end,
  setBackgroundColor = function() end, setTextColor = function() end,
  clear = function() screens[owner(_G.term._current) or 'term'] = {} end,
  setCursorPos = function(x, y) cursor.x, cursor.y = x, y end,
  write = function(text)
    local key = owner(_G.term._current) or 'term'
    local screen = screens[key] or {}
    screens[key] = screen
    local row = screen[cursor.y] or string.rep(' ', 80)
    text = tostring(text)
    row = row:sub(1, cursor.x - 1) .. text .. row:sub(cursor.x + #text)
    screen[cursor.y] = row
    cursor.x = cursor.x + #text
  end,
  getSize = function() return 51, 19 end,
}
local function row_of(mon, y) return ((screens[mon] or {})[y] or ''):gsub('%s+$', '') end
local function find_row(mon, pattern)
  for y = 1, 40 do
    if row_of(mon, y):find(pattern, 1, true) then return y end
  end
  return nil
end

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

local function mk_mon(w, h) return { getSize = function() return w, h end, setTextScale = function() end, isColor = function() return true end } end
local monitors = {
  { id = 'M1', name = 'm1', mon = mk_mon(60, 30) }, { id = 'M2', name = 'm2', mon = mk_mon(60, 30) },
  { id = 'M3', name = 'm3', mon = mk_mon(60, 30) }, { id = 'M4', name = 'aux', mon = mk_mon(60, 30) },
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

-- Bewusst KEIN erzwungenes Neuzeichnen je Durchlauf: bis v836 setzte dieser
-- Helfer jede Sitzung auf "dirty" und verdeckte so, dass ein Tipp auf der
-- Seite (Auswahl, Reiter, Blaettern) das Modell nicht aendert und erst nach
-- bis zu 5 s sichtbar wurde. Jetzt muss der Tipp selbst neu zeichnen lassen.
local function draw()
  now = now + 1100
  controller.draw()
end
draw()
local sessions = view_manager.sessions:get_sessions()
sessions[4].view_key = 'alarms'
sessions[4].dirty = true
local function touch(x, y)
  view_manager:handle_input('aux', x, y)
  draw()
end

-- ══ 1. Leer: alles in Ordnung ═══════════════════════════════════════════

draw()
assert_true(row_of(aux, 1):find('AUX:MELDUNGEN', 1, true) ~= nil, 'die Statusleiste nennt die Seite beim Namen: ' .. row_of(aux, 1))
assert_true(find_row(aux, 'STOERUNG 0 | WARNUNG 0 | ZU QUITTIEREN 0') == 2, 'Zusammenfassung in Zeile 2')
assert_true(find_row(aux, 'Keine Meldungen') ~= nil, 'leer: Hinweis')

-- ══ 2. Eine Stoerung kommt: Zeile, Auswahl, Einzelheiten, Quittieren ════

nodes['RT-1'].offline = true
nodes['RT-1'].rt.problems = {}
tick(2)
nodes['FUEL-1'].rt = nil
draw()
local y = find_row(aux, 'Node offline')
assert_true(y ~= nil and y >= 5, 'die Stoerung steht in der Liste: ' .. tostring(row_of(aux, 5)))
assert_true(row_of(aux, y):find('RT-1', 1, true) ~= nil and row_of(aux, y):find('AN', 1, true) ~= nil,
  'mit Node und Zustand: ' .. row_of(aux, y))
assert_true(find_row(aux, 'STOERUNG 1') == 2)
assert_true(find_row(aux, 'Eintrag antippen') ~= nil, 'noch keine Auswahl')

-- Antippen waehlt aus und zeigt die Einzelheiten -- quittiert aber nicht.
touch(5, y)
assert_true(row_of(aux, y):sub(1, 1) == '>', 'ausgewaehlt: ' .. row_of(aux, y))
assert_true(find_row(aux, 'STOERUNG | RT-1 | AN seit') ~= nil, 'Einzelheiten der Auswahl')
assert_true(find_row(aux, 'RT-1 antwortet nicht') ~= nil, 'mit dem Text der Regel')
assert_true(not service:get_active()[1].acknowledged, 'Antippen allein quittiert nicht')

-- Die Tasten stehen in der letzten Zeile der Seite (Monitor 30 hoch, AUX
-- haelt 2 Zeilen fuer die Navigation frei -> Zeile 28).
local button_y = find_row(aux, 'QUITT.')
assert_eq(button_y, 28, 'Tastenzeile')
touch(2, button_y)
assert_true(service:get_active()[1].acknowledged, 'QUITT. quittiert -- ueber den AUX-Monitor')
assert_true(row_of(aux, find_row(aux, 'Node offline')):find(' Q', 1, true) ~= nil, 'als quittiert markiert')

-- Ein zweiter Tipp nimmt nichts zurueck.
touch(2, button_y)
assert_true(service:get_active()[1].acknowledged, 'bleibt quittiert')

-- ══ 3. RT meldet ein Problem: alle Zeilen in den Einzelheiten ═══════════

nodes['RT-1'].offline = false
nodes['RT-1'].rt.problems = { 'liefert 40% vom Soll (4.0k von 10.0k RF/t) seit 6 min', '- turbine_2: 300/900 U/min' }
tick(2)
draw()
y = find_row(aux, 'RT meldet ein Problem')
assert_true(y ~= nil, 'RT-Problem in der Liste')
touch(5, y)
assert_true(find_row(aux, 'liefert 40% vom Soll') ~= nil, 'erste Zeile der Node')
assert_true(find_row(aux, '- turbine_2: 300/900 U/min') ~= nil, 'auch die Turbinenzeile')
assert_true(find_row(aux, 'RT meldet ein Problem -- Details am Monitor von RT-1') ~= nil, 'Hinweis auf den RT-Monitor')
-- VERGESSEN gibt es nur fuer eine ausgefallene Node.
local vx = row_of(aux, 28):find('VERGESSEN', 1, true)
assert_eq(alarms.hit_test(sessions[4].render_mon, vx, 28), nil, 'VERGESSEN ist fuer eine laufende Node gesperrt')

-- ══ 4. Sperren und Entsperren ═══════════════════════════════════════════

local slot_x = math.floor((60 - 3) / 4) + 2 -- dritte Taste: SPERREN
local sperren_x = find_row(aux, 'SPERREN 1h') and (row_of(aux, button_y):find('SPERREN 1h', 1, true)) or slot_x
touch(sperren_x, button_y)
assert_eq(find_row(aux, 'RT meldet ein Problem'), nil, 'gesperrt: aus der Liste')
tick(3)
draw()
assert_eq(find_row(aux, 'RT meldet ein Problem'), nil, 'und kommt waehrend der Sperre nicht wieder')
assert_true(find_row(aux, 'ENTSPERREN (1)') == 3, 'ENTSPERREN im Kopf')
touch(row_of(aux, 3):find('ENTSPERREN', 1, true), 3)
tick(2)
draw()
assert_true(find_row(aux, 'RT meldet ein Problem') ~= nil, 'entsperrt: steht wieder da')
nodes['RT-1'].rt.problems = {}
tick(2)

-- ══ 5. Node vergessen: nur fuer eine ausgefallene Node ══════════════════

nodes['FUEL-1'].offline = true
tick(2)
draw()
y = find_row(aux, 'FUEL-1')
touch(5, y)
local vergessen_x = row_of(aux, button_y):find('VERGESSEN', 1, true)
assert_true(vergessen_x ~= nil)
local ampel_forgot
package.loaded['optional.master_ampel'] = { forget_node = function(id) ampel_forgot = id end }
touch(vergessen_x, button_y)
package.loaded['optional.master_ampel'] = nil
assert_eq(nodes['FUEL-1'], nil, 'die ausgefallene Node ist vergessen')
assert_eq(ampel_forgot, 'FUEL-1', 'auch die MASTER-Ampel vergisst sie')
assert_eq(find_row(aux, 'FUEL-1'), nil, 'und ihre Meldung mit')

-- Eine laufende Node vergisst der Controller nicht.
assert_true(controller.handle_action({ type = 'alert_forget_node', node_id = 'RT-1' }))
assert_true(nodes['RT-1'] ~= nil, 'laufende Node bleibt')

-- ══ 6. Verlauf ══════════════════════════════════════════════════════════

touch(row_of(aux, 3):find('VERLAUF', 1, true), 3)
assert_true(find_row(aux, 'EREIGNIS') == 4, 'Verlaufskopf')
assert_true(find_row(aux, 'KOMMT') ~= nil and find_row(aux, 'QUITT.') ~= nil, 'kommt/quittiert im Verlauf')
touch(row_of(aux, 3):find('LISTE', 1, true), 3)
assert_true(row_of(aux, 4):find('MELDUNG', 1, true) ~= nil, 'zurueck zur Liste')

-- ══ 7. Zeile 2 gehoert der Seite (keine Ueberlagerung) ══════════════════

nodes['RT-1'].offline = true
tick(2)
draw()
assert_true(row_of(aux, 2):find('STOERUNG', 1, true) == 2, 'auf der Meldungsseite schreibt multiview nicht in Zeile 2: '
  .. row_of(aux, 2))

-- ══ 8. Alle anderen AUX-Views bekommen ihre Tipps ebenfalls ═════════════

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
