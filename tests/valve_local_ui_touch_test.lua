package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die VALVE-Node hat keine lokale Bedienung mehr.
--
-- Betreiberwunsch (2026-09-29): der Sperrknopf soll raus. Er war das einzige
-- Bedienelement dort ("SAFE BLOCKIEREN + READBACK PRUEFEN") und hat den Aktor
-- unter FUEL weg auf BLOCKIERT gestellt, ohne dass die Lieferlogik davon
-- wusste. Gestellt wird jetzt ausschliesslich ueber den Ventilkanal.
--
-- Dieser Test haelt fest, dass wirklich nichts mehr klickbar ist -- nicht nur,
-- dass der Knopf nicht mehr gezeichnet wird: eine stehengebliebene
-- Trefferflaeche waere von aussen unsichtbar und trotzdem wirksam.

local draw = { buttons = {}, rows = {}, texts = {} }
local mux = {}
mux.fit = function(text, width)
  return tostring(text or ''):sub(1, math.max(0, tonumber(width) or 0))
end
mux.clear = function() end
mux.text = function(_target, x, y, text)
  draw.texts[#draw.texts + 1] = { x = x, y = y, text = tostring(text or '') }
end
mux.header = function() end
mux.status_dot = function() end
mux.card = function() end
mux.banner = function() end
mux.data_row = function(_target, x, y, w, opts)
  draw.rows[#draw.rows + 1] = {
    x = x, y = y, w = w,
    label = tostring(opts and opts.label or ''),
    value = tostring(opts and opts.value or ''),
    status = tostring(opts and opts.status or ''),
  }
end
mux.button = function(_target, x, y, w, label, status, h)
  local r = {
    x1 = x, x2 = x + w - 1,
    y = y, y2 = y + h - 1,
    label = label, status = status
  }
  draw.buttons[#draw.buttons + 1] = r
  return r
end
package.loaded['core.mockup_ui'] = mux
package.loaded['shared.colors'] = { get = function() return 1 end }
package.loaded['nodes.valve.local_ui'] = nil

local state = {
  current_high = false,
  initialized = true,
  last_write_error = nil,
  last_command_ts = 1000,
  sorter_name = 'sorter_0',
  actuator_mode = 'sorter',
  redstone_side = nil,
  trusted_source = 'FUEL-1',
  pairing_persisted = true,
  pairing_error = nil,
}

-- Die lokale Oberflaeche darf den Aktor ueberhaupt nicht mehr anfassen.
-- apply_valve() zaehlt deshalb nicht nur mit, es ist ein Fehler, wenn es
-- ueberhaupt aufgerufen wird.
local writes = {}
local controller = {
  get_state = function() return state end,
  apply_valve = function(_self, high, force)
    writes[#writes + 1] = { high = high, force = force }
    return true
  end,
}

local width, height = 51, 19
local target = {
  getSize = function() return width, height end,
  clear = function() end,
  setBackgroundColor = function() end,
}

local now = 11000
local os_api = { epoch = function() return now end }

local hop = {
  configured = true,
  enabled = true,
  chest = 'minecraft:chest_5',
  interval_s = 4,
  last_scan_ms = 9000,
  modem_ready = true,
}

local ui = require('nodes.valve.local_ui').new({
  controller = controller,
  node_id = 'VALVE-7',
  label = 'Reaktor A Einlass',
  modem_name = 'right',
  target = target,
  os_api = os_api,
  is_master_reachable = function() return true end,
  get_comms_diagnostics = function() return { queue_depth = 0 } end,
  get_hop_status = function() return hop end,
})

assert(ui:render(true) == true)

-- 1. Kein Knopf mehr, in keiner Form.
assert(#draw.buttons == 0,
  'die lokale VALVE-Oberflaeche darf kein Bedienelement mehr zeichnen')
assert(ui:get_touch_geometry().safe_button == nil,
  'es darf auch keine Trefferflaeche mehr geben')

-- 2. Der Platz zeigt statt des Knopfs den Ventilzustand. Die Aussage, die
--    vorher in der Knopffarbe steckte, darf mit ihm nicht verschwinden.
local valve_row = nil
for _, row in ipairs(draw.rows) do
  if row.y == 15 and row.label == 'VENTIL' then valve_row = row end
end
assert(valve_row, 'Zustandszeile VENTIL muss auf Zeile 15 stehen')
assert(valve_row.value == 'OFFEN', 'current_high=false muss OFFEN heissen')

-- 3. Die HOP-Zeile bleibt, wo sie war.
local hop_row_found = false
for _, row in ipairs(draw.rows) do
  if row.y == 13 and row.label:find('HOP', 1, true) then
    hop_row_found = true
    assert(row.x == 2 and row.w == 48)
  end
end
assert(hop_row_found, 'HOP-Zusammenfassung muss auf Zeile 13 stehen')

-- 4. Kein Klick wird mehr behandelt, und keiner erreicht den Aktor --
--    geprueft auf genau den Punkten, die den Knopf frueher ausgeloest
--    haben (Ecken und Mitte seines Rechtecks), plus daneben.
local points = { {2,14}, {49,14}, {2,16}, {49,16}, {25,15},
                 {1,14}, {50,14}, {2,13}, {2,17} }
for _, p in ipairs(points) do
  assert(ui:handle_event({ 'mouse_click', 1, p[1], p[2] }) == false,
    'Klick auf ' .. p[1] .. '/' .. p[2] .. ' darf nicht behandelt werden')
end
assert(#writes == 0, 'kein Klick darf den Aktor schalten')

-- 5. Auch der kompakte Aufbau (ui_scale 0.5) hat keinen Knopf.
draw.buttons = {}
draw.rows = {}
draw.texts = {}
local compact = require('nodes.valve.local_ui').new({
  controller = controller,
  node_id = 'VALVE-7',
  label = 'Reaktor A Einlass',
  modem_name = 'right',
  target = target,
  os_api = os_api,
  ui_scale = 0.5,
  is_master_reachable = function() return true end,
  get_comms_diagnostics = function() return { queue_depth = 0 } end,
  get_hop_status = function() return hop end,
})
assert(compact:render(true) == true)
assert(#draw.buttons == 0, 'auch die kompakte Ansicht zeichnet keinen Knopf')
assert(compact:get_touch_geometry().safe_button == nil)
local compact_valve = false
for _, t in ipairs(draw.texts) do
  if t.y == 12 and t.text:find('VENTIL', 1, true) then compact_valve = true end
end
assert(compact_valve, 'die kompakte Ansicht zeigt den Ventilzustand auf Zeile 12')
for _, p in ipairs({ {8,11}, {43,11}, {25,12}, {8,13}, {43,13} }) do
  assert(compact:handle_event({ 'mouse_click', 1, p[1], p[2] }) == false)
end
assert(#writes == 0)

-- 6. Ein blockiertes Ventil wird als solches angezeigt.
draw.rows = {}
state.current_high = true
ui.force_redraw = true
ui:render(true)
local blocked_row = nil
for _, row in ipairs(draw.rows) do
  if row.y == 15 and row.label == 'VENTIL' then blocked_row = row end
end
assert(blocked_row and blocked_row.value == 'BLOCKIERT',
  'current_high=true muss BLOCKIERT heissen')
assert(blocked_row.status == 'OK', 'bestaetigt blockiert ist OK')

-- 7. Ein Schreibfehler schlaegt den Zustand.
draw.rows = {}
state.last_write_error = 'sorter weg'
ui.force_redraw = true
ui:render(true)
for _, row in ipairs(draw.rows) do
  if row.y == 15 and row.label == 'VENTIL' then
    assert(row.value == 'SCHREIBFEHLER' and row.status == 'WARNING',
      'ein Schreibfehler muss die Zustandszeile uebersteuern')
  end
end
state.last_write_error = nil

-- 8. term_resize wird weiterhin angenommen (Neuzeichnen), aber als
--    "nicht behandelt" gemeldet -- wie bisher.
ui.force_redraw = false
assert(ui:handle_event({ 'term_resize' }) == false)
assert(ui.force_redraw == true, 'term_resize muss ein Neuzeichnen anstossen')

print('valve_local_ui_touch_test.lua: ok')
