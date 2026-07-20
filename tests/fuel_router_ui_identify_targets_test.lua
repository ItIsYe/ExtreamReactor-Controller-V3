package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer die "Weg 3"-Idee des Melders (Identify/Locate-Hilfe,
-- Fix 2026-07-20, siehe nodes/fuel/router_ui.lua get_identify_targets()):
-- liefert die eindeutigen VALVE-Node-IDs, die GERADE JETZT bearbeitet
-- werden (nur waehrend edit_view=="path" mit gesetztem u.editing), leer in
-- jedem anderen Zustand (TREE-Tab, EDIT-Listenansicht, nach ABBRECHEN/
-- FERTIG). Treibt handle_touch() genau wie tests/fuel_router_ui_multi_
-- valve_chain_builder_test.lua.

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

local function sorted(list)
  local copy = {}
  for i, v in ipairs(list) do copy[i] = v end
  table.sort(copy)
  return copy
end

local comms = {
  get_peers = function() return {
    ['VALVE-1'] = { down = false, role = 'VALVE-NODE' },
    ['VALVE-2'] = { down = false, role = 'VALVE-NODE' },
  } end,
}
local rs = redstone_router.new({
  config = { logistics = { redstone_tree = {} } },
  comms = comms, log = function() end, warn_once = function() end,
})
rs:refresh()

local ui = router_ui.new({
  redstone_router = rs,
  config_path = '/xreactor/config/fuel_routes.lua',
  get_reactors = function() return { { id = 'R1', label = 'Reactor1' } } end,
  log = function() end,
})

-- 1. TREE-Tab (Ausgangszustand): keine Identify-Ziele.
assert_eq(#ui:get_identify_targets(), 0, 'the tree tab must never report identify targets')

-- 2. EDIT-Tab, Listenansicht (kein Reaktor ausgewaehlt): ebenfalls leer.
ui._ui.edit_btn = { x1 = 10, x2 = 15, y = 3 }
ui:handle_touch(12, 3)
assert_eq(ui._ui.edit_view, 'list')
assert_eq(#ui:get_identify_targets(), 0, 'the edit list view (no reactor selected) must report no identify targets')

-- 3. Reaktor auswaehlen -> Pfad-Editor: noch leere Kette -> noch keine Ziele.
ui._ui.reactor_btns = { { x1 = 4, x2 = 40, y = 8, id = 'R1', label = 'Reactor1' } }
ui:handle_touch(10, 8)
assert_eq(ui._ui.edit_view, 'path')
assert_eq(#ui:get_identify_targets(), 0, 'an empty chain must report no identify targets')

-- 4. Ersten Schritt anfuegen (VALVE-1) -> genau dieses Ziel wird gemeldet.
ui._ui.side_btns = { { x1 = 4, x2 = 40, y = 9, side = 'back' } }
ui:handle_touch(10, 9)
ui._ui.integrator_btns = {
  { x1 = 4, x2 = 40, y = 11, integrator = nil },
  { x1 = 4, x2 = 40, y = 12, integrator = 'VALVE-1' },
}
ui:handle_touch(10, 12)
assert_eq(#ui._ui.editing.path, 1)
local targets1 = ui:get_identify_targets()
assert_eq(#targets1, 1)
assert_eq(targets1[1], 'VALVE-1')

-- 5. Zweiten Schritt anfuegen (VALVE-2, lokal ohne Integrator wird
--    ausgeschlossen -- nur echte VALVE-Nodes werden identifiziert): beide
--    Ziele werden gemeldet, dedupliziert und eine lokale Seite (integrator
--    == nil) traegt nichts bei.
ui._ui.side_btns = { { x1 = 4, x2 = 40, y = 9, side = 'left' } }
ui:handle_touch(10, 9)
ui._ui.integrator_btns = {
  { x1 = 4, x2 = 40, y = 11, integrator = nil },
  { x1 = 4, x2 = 40, y = 12, integrator = 'VALVE-2' },
}
ui:handle_touch(10, 12)
ui._ui.side_btns = { { x1 = 4, x2 = 40, y = 9, side = 'right' } }
ui:handle_touch(10, 9)
ui._ui.integrator_btns = { { x1 = 4, x2 = 40, y = 11, integrator = nil } }
ui:handle_touch(10, 11) -- lokaler Schritt, kein Integrator
assert_eq(#ui._ui.editing.path, 3)
local targets2 = sorted(ui:get_identify_targets())
assert_eq(#targets2, 2, 'the local (integrator=nil) step must not be reported as an identify target')
assert_eq(targets2[1], 'VALVE-1')
assert_eq(targets2[2], 'VALVE-2')

-- 6. Denselben Integrator ein zweites Mal anfuegen (geteiltes Trunk-Ventil)
--    -- darf im Ergebnis nicht doppelt auftauchen.
ui._ui.side_btns = { { x1 = 4, x2 = 40, y = 9, side = 'front' } }
ui:handle_touch(10, 9)
ui._ui.integrator_btns = { { x1 = 4, x2 = 40, y = 11, integrator = 'VALVE-1' } }
ui:handle_touch(10, 11)
assert_eq(#ui._ui.editing.path, 4)
assert_eq(#ui:get_identify_targets(), 2, 'a repeated integrator (shared valve) must not be reported twice')

-- 7. ABBRECHEN: zurueck in die Listenansicht -- keine Identify-Ziele mehr,
--    obwohl die verworfene Arbeitskopie noch Schritte enthielt.
ui._ui.cancel_btn = { x1 = 30, x2 = 40, y = 20 }
ui:handle_touch(35, 20)
assert_eq(ui._ui.edit_view, 'list')
assert_eq(#ui:get_identify_targets(), 0, 'leaving the path editor (cancel) must stop reporting identify targets')

print("fuel_router_ui_identify_targets_test.lua: ok")
