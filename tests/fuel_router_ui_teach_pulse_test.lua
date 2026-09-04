package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer die "Weg 3"-Idee des Melders: Route-Teach-in per
-- manuellem Redstone-INPUT (Fix 2026-07-20, siehe nodes/fuel/router_ui.lua
-- handle_teach_pulse()). Waehrend der Teach-Modus (u.teaching, per Button
-- in der Ventilketten-Ansicht umschaltbar) aktiv ist, haengt jeder
-- eingehende ROUTE_TEACH_PULSE (ausgeloest durch einen physisch am Ventil
-- umgelegten Hebel, siehe nodes/valve/main.lua) die meldende Node in
-- GENAU DIESER Reihenfolge an die gerade bearbeitete Kette an. Treibt
-- handle_touch() wie tests/fuel_router_ui_multi_valve_chain_builder_test.lua.
--
-- 2026-09-04: an das neue Einzelbildschirm-Schema angepasst (u.mode
-- "list"/"edit"/"path" statt der alten edit_view-Unterscheidung; Reaktoren
-- tragen reactor_id statt id, path bleibt eine flache Liste von VALVE-Ids).

_G.fs = {
  exists = function() return false end,
  getDir = function(p) return (p:match("^(.*)/[^/]+$")) or "" end,
  makeDir = function() end,
  delete = function() end,
  move = function() end,
  open = function() return nil end,
}
_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
  getNames = function() return {} end,
}

local redstone_router = require('nodes.fuel.redstone_router')
local router_ui = require('nodes.fuel.router_ui')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local rs = redstone_router.new({
  config = { logistics = { redstone_tree = {} } },
  comms = { get_peers = function() return {} end },
  log = function() end, warn_once = function() end,
})
rs:refresh()

local config = {
  logistics = {
    reactors = { { reactor_id = 'R1', label = 'Reactor1', inlet = nil, path = {}, request_below = 0.25, fill_amount = 64, min_in_me = 32 } },
  },
}

local ui = router_ui.new({
  config = config,
  redstone_router = rs,
  config_path = '/xreactor_config/fuel_routes.lua',
  get_reactors = function() return {} end,
  log = function() end,
})

-- 1. Ausserhalb des Pfad-Editors ("list"-Bildschirm): ein Puls wird ignoriert.
assert_true(not ui:handle_teach_pulse('VALVE-1'), 'a teach pulse must be ignored outside the path editor')

-- 2. Reaktor antippen -> "edit", dann PFAD-Zeile antippen -> "path". Teach-
--    Modus ist zu Beginn NICHT aktiv: weiterhin ignoriert.
ui._ui.reactor_btns = { { x1 = 4, x2 = 40, y = 8, reactor_id = 'R1' } }
ui:handle_touch(10, 8)
assert_eq(ui._ui.mode, 'edit')
ui._ui.path_row = { x1 = 4, x2 = 40, y = 5 }
ui:handle_touch(10, 5)
assert_eq(ui._ui.mode, 'path')
assert_true(not ui._ui.teaching, 'teach mode must start OFF')
assert_true(not ui:handle_teach_pulse('VALVE-1'), 'a teach pulse must be ignored while teach mode is off')
assert_eq(#ui._ui.editing.path, 0)

-- 3. Teach-Modus per Button aktivieren -- jetzt haengt ein Puls die Node an.
ui._ui.teach_btn = { x1 = 2, x2 = 20, y = 4 }
assert_true(ui:handle_touch(5, 4), 'tapping the teach toggle must be consumed')
assert_true(ui._ui.teaching, 'the teach toggle must flip u.teaching on')

assert_true(ui:handle_teach_pulse('VALVE-1'), 'a teach pulse while active must be accepted')
assert_eq(#ui._ui.editing.path, 1)
assert_eq(ui._ui.editing.path[1], 'VALVE-1')

-- 4. Zweiter Puls von einer ANDEREN Node haengt sich in der gemeldeten
--    Reihenfolge an.
assert_true(ui:handle_teach_pulse('VALVE-2'))
assert_eq(#ui._ui.editing.path, 2)
assert_eq(ui._ui.editing.path[2], 'VALVE-2')

-- 5. Ein sofort wiederholter Puls DERSELBEN Node (Doppel-Puls/Prellen)
--    haengt sich NICHT ein zweites Mal in Folge an.
assert_true(not ui:handle_teach_pulse('VALVE-2'), 'an immediate repeat of the same node must be ignored (debounce)')
assert_eq(#ui._ui.editing.path, 2, 'a debounced repeat must not grow the chain')

-- 6. Dieselbe Node SPAETER (nach einer anderen dazwischen) darf erneut
--    auftauchen -- ein geteiltes Trunk-Ventil ist ein gueltiger Use-Case.
assert_true(ui:handle_teach_pulse('VALVE-3'))
assert_true(ui:handle_teach_pulse('VALVE-1'))
assert_eq(#ui._ui.editing.path, 4)
assert_eq(ui._ui.editing.path[4], 'VALVE-1')

-- 7. Teach-Modus erneut antippen schaltet ihn wieder aus.
assert_true(ui:handle_touch(5, 4))
assert_true(not ui._ui.teaching)
assert_true(not ui:handle_teach_pulse('VALVE-9'), 'a pulse after disabling teach mode must be ignored again')
assert_eq(#ui._ui.editing.path, 4)

-- 8. ABBRECHEN setzt den Teach-Modus zurueck (fuer die naechste Bearbeitung).
ui._ui.teach_btn = { x1 = 2, x2 = 20, y = 4 }
ui:handle_touch(5, 4) -- wieder an
assert_true(ui._ui.teaching)
ui._ui.path_cancel_btn = { x1 = 30, x2 = 40, y = 20 }
ui:handle_touch(35, 20)
assert_eq(ui._ui.mode, 'edit')
assert_true(not ui._ui.teaching, 'leaving the path editor (cancel) must reset teach mode')

print("fuel_router_ui_teach_pulse_test.lua: ok")
