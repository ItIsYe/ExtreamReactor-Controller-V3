package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer den Ventilketten-Editor auf der FUEL-Router-Seite
-- (siehe nodes/fuel/router_ui.lua), an das 2026-09-04-Einzelbildschirm-
-- Schema angepasst: Reaktor einlernen (aus einer live-meldenden RT-Node,
-- kein manuell getippter Name mehr) -> Inlet setzen -> Ventil fuer Ventil
-- antippen -> FERTIG. Treibt handle_touch() direkt (Touch-Zonen werden
-- manuell so gesetzt, wie render() sie gesetzt haette, ohne den vollen
-- Monitor-/mux-Renderpfad zu mocken) und beweist den kompletten Ablauf
-- End-to-End inklusive atomarem Speichern.

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

local config = { logistics = { reactors = {} } }
local live_reactors = { { id = 'R1', label = 'Reactor1' }, { id = 'R2', label = 'Reactor2' } }
local refresh_calls = 0
local logistics_router_stub = { refresh_peripherals = function() refresh_calls = refresh_calls + 1 end }

local logistics_enabled_calls = {}
local ui = router_ui.new({
  config = config,
  redstone_router = rs,
  logistics_router = logistics_router_stub,
  config_path = '/xreactor_config/fuel_routes.lua',
  get_reactors = function() return live_reactors end,
  log = function() end,
  set_logistics_enabled = function(value) logistics_enabled_calls[#logistics_enabled_calls + 1] = value end,
})

assert_eq(#ui._ui.reactors, 0, 'must start with no reactors configured')
assert_eq(ui._ui.mode, 'list', 'must start on the single main screen')
assert_eq(ui._ui.export_chest, nil, 'must start with no export chest configured')
assert_eq(ui._ui.logistics_enabled, false, 'logistics.enabled must default to false (safety switch)')

-- ── EXPORT-KISTE antippen -> Picker mit erkannten Peripherals ──────────────
ui._ui.export_chest_btn = { x1 = 2, x2 = 20, y = 4 }
assert_true(ui:handle_touch(5, 4), 'tapping EXPORT-KISTE must be consumed')
assert_eq(ui._ui.mode, 'chest_pick')
ui._ui.chest_btns = { { x1 = 4, x2 = 40, y = 8, name = 'transporter_0' } }
assert_true(ui:handle_touch(10, 8), 'tapping a peripheral must be consumed')
assert_eq(ui._ui.mode, 'list', 'picking a chest returns straight to the main screen, not "edit"')
assert_eq(ui._ui.export_chest, 'transporter_0')
assert_true(ui._ui.dirty, 'setting the export chest must mark the page dirty')

-- ── LOGISTIK antippen -> schaltet sofort um und persistiert direkt, kein ──
--    SPEICHERN/dirty-Batching wie bei Reaktoren/Export-Kiste (Sicherheits-
--    Schalter, siehe router_ui.lua's set_logistics_enabled-Kommentar). ────
ui._ui.logistics_btn = { x1 = 2, x2 = 20, y = 5 }
assert_true(ui:handle_touch(5, 5), 'tapping LOGISTIK must be consumed')
assert_eq(ui._ui.logistics_enabled, true, 'first tap must turn logistics on')
assert_eq(#logistics_enabled_calls, 1)
assert_eq(logistics_enabled_calls[1], true, 'set_logistics_enabled must be called with the new value')
assert_true(ui:handle_touch(5, 5), 'tapping LOGISTIK again must be consumed')
assert_eq(ui._ui.logistics_enabled, false, 'second tap must turn logistics back off')
assert_eq(#logistics_enabled_calls, 2)
assert_eq(logistics_enabled_calls[2], false)

-- ── EINLERNEN antippen -> Picker mit den live meldenden Reaktoren ──────────
ui._ui.learn_btn = { x1 = 2, x2 = 20, y = 6 }
assert_true(ui:handle_touch(5, 6), 'tapping EINLERNEN must be consumed')
assert_eq(ui._ui.mode, 'learn')

-- ── Reactor2 antippen -> Bearbeitung startet mit dem echten gelernten Namen ─
ui._ui.learn_btns = { { x1 = 4, x2 = 40, y = 8, id = 'R2', label = 'Reactor2' } }
assert_true(ui:handle_touch(10, 8), 'tapping a learnable reactor row must be consumed')
assert_eq(ui._ui.mode, 'edit')
assert_true(ui._ui.editing ~= nil)
assert_eq(ui._ui.editing.reactor_id, 'R2')
assert_eq(ui._ui.editing.label, 'Reactor2')
assert_eq(#ui._ui.editing.path, 0)

-- ── PFAD-Zeile antippen -> Ventilketten-Editor fuer R2 ─────────────────────
ui._ui.path_row = { x1 = 4, x2 = 40, y = 5 }
assert_true(ui:handle_touch(10, 5))
assert_eq(ui._ui.mode, 'path')

-- ── Ersten VALVE-Node antippen -- ein Pfad-Eintrag ist direkt die ─────────
--    VALVE-Node-ID, kein Zwischenschritt mehr noetig. ─────────────────────
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

-- ── Pfad-FERTIG: zurueck zum Formular, noch nicht in u.reactors uebernommen ─
ui._ui.path_done_btn = { x1 = 2, x2 = 12, y = 20 }
assert_true(ui:handle_touch(5, 20))
assert_eq(ui._ui.mode, 'edit')
assert_eq(#ui._ui.reactors, 0, 'the path editor must not commit by itself')

-- ── Formular-FERTIG: committet die Arbeitskopie in u.reactors ──────────────
ui._ui.edit_done_btn = { x1 = 2, x2 = 12, y = 22 }
assert_true(ui:handle_touch(5, 22))
assert_eq(ui._ui.mode, 'list')
assert_eq(#ui._ui.reactors, 1)
assert_eq(ui._ui.reactors[1].reactor_id, 'R2')
assert_eq(#ui._ui.reactors[1].path, 1)
assert_true(ui._ui.dirty)

-- ── Reactor1 bekommt bewusst KEINE Ventilkette (direkter Export ohne ───────
--    Ventil-Gating ist weiterhin ein gueltiger Anwendungsfall). ────────────
ui._ui.learn_btn = { x1 = 2, x2 = 20, y = 6 }
ui:handle_touch(5, 6)
ui._ui.learn_btns = { { x1 = 4, x2 = 40, y = 8, id = 'R1', label = 'Reactor1' } }
assert_true(ui:handle_touch(10, 8))
assert_eq(ui._ui.editing.reactor_id, 'R1')
ui._ui.edit_done_btn = { x1 = 2, x2 = 12, y = 22 }
assert_true(ui:handle_touch(5, 22))
assert_eq(#ui._ui.reactors, 2)

-- ── ABBRECHEN darf einen bestehenden Reaktor NICHT veraendern ──────────────
ui._ui.reactor_btns = { { x1 = 4, x2 = 40, y = 8, reactor_id = 'R2' } }
assert_true(ui:handle_touch(10, 8))
ui._ui.path_row = { x1 = 4, x2 = 40, y = 5 }
assert_true(ui:handle_touch(10, 5))
ui._ui.integrator_btns = { { x1 = 4, x2 = 40, y = 11, integrator = 'VALVE-2' } }
assert_true(ui:handle_touch(10, 11)) -- editing.path now has 2 steps
assert_eq(#ui._ui.editing.path, 2)
ui._ui.path_done_btn = { x1 = 2, x2 = 12, y = 20 }
ui:handle_touch(5, 20)
ui._ui.edit_cancel_btn = { x1 = 30, x2 = 40, y = 22 }
assert_true(ui:handle_touch(35, 22))
assert_eq(ui._ui.mode, 'list')
assert_eq(ui._ui.editing, nil)
assert_eq(#ui._ui.reactors[1].path, 1, 'ABBRECHEN must discard the working copy, the committed reactor stays unchanged')

-- ── SPEICHERN: validiert, schreibt atomar, aktualisiert config + stoesst ───
--    logistics_router:refresh_peripherals() an. ───────────────────────────
ui._ui.save_btn = { x1 = 2, x2 = 20, y = 24 }
assert_true(ui:handle_touch(5, 24))
assert_eq(ui._ui.save.state, 'SAVED', 'save must succeed: ' .. tostring(ui._ui.save.error))
assert_true(not ui._ui.dirty)
assert_eq(refresh_calls, 1, 'a successful save must refresh the logistics router once')
assert_eq(#config.logistics.reactors, 2, 'the live config must be updated with the saved snapshot')
assert_eq(config.logistics.export_chest, 'transporter_0', 'the live config must be updated with the saved export chest')

-- Die gespeicherte Datei ist mit dofile ladbar und traegt die Export-Kiste
-- sowie beide Reaktoren mit ihren gelernten Namen und dem konfigurierten Pfad.
local persisted = dofile('/xreactor_config/fuel_routes.lua')
assert_eq(persisted.export_chest, 'transporter_0')
assert_eq(#persisted.reactors, 2)
local by_id = {}
for _, r in ipairs(persisted.reactors) do by_id[r.reactor_id] = r end
assert_true(by_id.R1 ~= nil and by_id.R2 ~= nil)
assert_eq(#by_id.R2.path, 1)
assert_eq(by_id.R2.path[1], 'VALVE-1')
assert_eq(#by_id.R1.path, 0)

-- ── RESET verwirft nicht gespeicherte Aenderungen und laedt aus der ────────
--    zuletzt gespeicherten config.logistics.reactors zurueck. ─────────────
ui._ui.reset_btn = { x1 = 41, x2 = 50, y = 24 }
assert_true(ui:handle_touch(45, 24))
assert_eq(#ui._ui.reactors, 2, 'RESET must reload the last-saved reactor list, not clear it')
assert_eq(ui._ui.export_chest, 'transporter_0', 'RESET must reload the last-saved export chest too')
assert_true(not ui._ui.dirty)

print("fuel_router_ui_multi_valve_chain_builder_test.lua: ok")
