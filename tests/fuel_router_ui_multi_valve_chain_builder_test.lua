package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer den mehrstufigen Ventilketten-Editor auf der
-- FUEL-Router-Seite (siehe nodes/fuel/router_ui.lua). Reaktor waehlen ->
-- Ventil fuer Ventil antippen (aus den bekannten VALVE-Nodes) -> FERTIG.
-- Dieser Test treibt handle_touch() direkt (dieselbe Technik wie
-- tests/ui_router_page_nav_debounce_test.lua: Touch-Zonen werden manuell so
-- gesetzt, wie render() sie gesetzt haette, ohne den vollen Monitor-/mux-
-- Renderpfad zu mocken) und beweist den kompletten Ablauf End-to-End
-- inklusive Speichern + Uebernahme durch den echten redstone_router.
--
-- Feature (2026-09-03): der fruehere zweistufige Picker (erst Seite, dann
-- optional ein VALVE-Node dafuer) ist einem einstufigen Picker gewichen --
-- ein Pfad-Eintrag ist jetzt direkt die VALVE-Node-ID (String), kein
-- {side=,integrator=}-Paar mehr.

local files = {}

_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function(p) return (p:match("^(.*)/[^/]+$")) or "" end,
  makeDir = function() end,
  delete = function(p) files[p] = nil end,
  move = function(src, dst) files[dst] = files[src]; files[src] = nil end,
  open = function(p, mode)
    if mode == "w" then
      local buf = {}
      return {
        writeLine = function(line) buf[#buf + 1] = line end,
        write = function(s) buf[#buf + 1] = s end,
        close = function() files[p] = table.concat(buf, "\n") .. "\n" end,
      }
    elseif mode == "r" then
      if not files[p] then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
}
_G.dofile = function(path)
  local content = files[path]
  if not content then error("dofile: no such mock file: " .. tostring(path), 0) end
  local chunk, err = load(content, "=" .. path)
  if not chunk then error("dofile parse error: " .. tostring(err), 0) end
  return chunk()
end
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

local reactors = { { id = 'R1', label = 'Reactor1' }, { id = 'R2', label = 'Reactor2' } }
local ui = router_ui.new({
  redstone_router = rs,
  config_path = '/xreactor/config/fuel_routes.lua',
  get_reactors = function() return reactors end,
  log = function() end,
})

assert_eq(#ui._ui.routes, 0, 'must start with no routes configured')
assert_eq(ui._ui.mode, 'tree', 'must start on the tree tab')

-- ── Tab wechseln: TREE -> EDIT ───────────────────────────────────────────────
ui._ui.edit_btn = { x1 = 10, x2 = 15, y = 3 }
assert_true(ui:handle_touch(12, 3), 'tapping the EDIT tab must be consumed')
assert_eq(ui._ui.mode, 'edit')
assert_eq(ui._ui.edit_view, 'list')

-- ── Reactor2 antippen -> Pfad-Editor fuer R2 oeffnet mit leerer Kette ───────
ui._ui.reactor_btns = { { x1 = 4, x2 = 40, y = 8, id = 'R2', label = 'Reactor2' } }
assert_true(ui:handle_touch(10, 8), 'tapping a reactor row must be consumed')
assert_eq(ui._ui.edit_view, 'path')
assert_true(ui._ui.editing ~= nil)
assert_eq(ui._ui.editing.reactor, 'R2')
assert_eq(#ui._ui.editing.path, 0)

-- ── Ersten VALVE-Node antippen -- ein Pfad-Eintrag ist jetzt direkt die ────
--    VALVE-Node-ID, kein Zwischenschritt mehr noetig. ──────────────────────
ui._ui.integrator_btns = { { x1 = 4, x2 = 40, y = 11, integrator = 'VALVE-2' } }
assert_true(ui:handle_touch(10, 11))
assert_eq(#ui._ui.editing.path, 1)
assert_eq(ui._ui.editing.path[1], 'VALVE-2')

-- ── Zweiter Schritt: ein weiterer bekannter VALVE-Node. ─────────────────────
ui._ui.integrator_btns = {
  { x1 = 4, x2 = 40, y = 11, integrator = 'VALVE-2' },
  { x1 = 4, x2 = 40, y = 12, integrator = 'VALVE-1' },
}
assert_true(ui:handle_touch(10, 12))
assert_eq(#ui._ui.editing.path, 2)
assert_eq(ui._ui.editing.path[2], 'VALVE-1')

-- ── ersten Schritt wieder entfernen (in der Kettenliste antippen) ──────────
ui._ui.step_btns = { { x1 = 4, x2 = 40, y = 7, index = 1 } }
assert_true(ui:handle_touch(10, 7))
assert_eq(#ui._ui.editing.path, 1, 'removing step 1 must leave only the former second step')
assert_eq(ui._ui.editing.path[1], 'VALVE-1')

-- ── FERTIG: committet die Arbeitskopie in u.routes ──────────────────────────
ui._ui.done_btn = { x1 = 2, x2 = 12, y = 20 }
assert_true(ui:handle_touch(5, 20))
assert_eq(ui._ui.edit_view, 'list')
assert_eq(#ui._ui.routes, 1)
assert_eq(ui._ui.routes[1].reactor, 'R2')
assert_eq(#ui._ui.routes[1].path, 1)
assert_true(ui._ui.dirty)

-- ── Reactor1 bekommt bewusst KEINE Ventilkette (direkter Export ohne ───────
--    Ventil-Gating ist weiterhin ein gueltiger Anwendungsfall). ────────────
ui._ui.reactor_btns = { { x1 = 4, x2 = 40, y = 8, id = 'R1', label = 'Reactor1' } }
assert_true(ui:handle_touch(10, 8))
assert_eq(ui._ui.editing.reactor, 'R1')
ui._ui.done_btn = { x1 = 2, x2 = 12, y = 20 }
assert_true(ui:handle_touch(5, 20))
assert_eq(#ui._ui.routes, 2)

-- ── ABBRECHEN darf eine bestehende Route NICHT veraendern ───────────────────
ui._ui.reactor_btns = { { x1 = 4, x2 = 40, y = 8, id = 'R2', label = 'Reactor2' } }
assert_true(ui:handle_touch(10, 8))
ui._ui.integrator_btns = { { x1 = 4, x2 = 40, y = 11, integrator = 'VALVE-2' } }
assert_true(ui:handle_touch(10, 11)) -- editing.path now has 2 steps
assert_eq(#ui._ui.editing.path, 2)
ui._ui.cancel_btn = { x1 = 30, x2 = 40, y = 20 }
assert_true(ui:handle_touch(35, 20))
assert_eq(ui._ui.edit_view, 'list')
assert_eq(ui._ui.editing, nil)
assert_eq(#ui._ui.routes[1].path, 1, 'ABBRECHEN must discard the working copy, the committed route stays unchanged')

-- ── SPEICHERN: validiert, schreibt atomar, aktualisiert den echten Router ──
ui._ui.save_btn = { x1 = 2, x2 = 20, y = 22 }
assert_true(ui:handle_touch(5, 22))
assert_eq(ui._ui.save.state, 'SAVED', 'save must succeed: ' .. tostring(ui._ui.save.error))
assert_true(not ui._ui.dirty)

-- Der ECHTE redstone_router kennt jetzt beide Routen.
local path_to_r2 = rs:get_path_to('R2')
assert_eq(#path_to_r2, 1)
assert_eq(path_to_r2[1], 'VALVE-1')
local rtable = rs:get_routing_table()
assert_eq(#rtable, 2, 'both reactors must be present in the live routing table')

-- Die gespeicherte Datei ist mit derselben Validierung ladbar, die der
-- Router selbst verwendet.
local persisted = dofile('/xreactor/config/fuel_routes.lua')
assert_eq(#persisted, 2)
local validation = redstone_router.validate_tree(persisted)
assert_true(validation.ok, 'the persisted file must itself validate cleanly')

-- ── RESET leert alle Routen (muss anschliessend erneut speicherbar sein) ───
ui._ui.reset_btn = { x1 = 41, x2 = 50, y = 22 }
assert_true(ui:handle_touch(45, 22))
assert_eq(#ui._ui.routes, 0)
assert_true(ui._ui.dirty)

print("fuel_router_ui_multi_valve_chain_builder_test.lua: ok")
