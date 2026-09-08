package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Smoke test: M:render() darf in KEINEM u.mode einen Lua-Laufzeitfehler
-- werfen (nil-Zugriff, falsche Argumentanzahl etc.) -- exercised alle
-- fuenf Zustaende des einzelnen Hauptbildschirms (list / learn / edit /
-- inlet_pick / path). Nutzt ein minimales Monitor-Mock -- core/mockup_ui.lua's
-- safe_call() toleriert fehlende Methoden bereits (kein Absturz bei einem
-- "nackten" Monitor-Objekt), daher reicht ein Mock, der nur getSize()
-- beantwortet.

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
  getNames = function() return {} end,
}
_G.redstone = { setOutput = function() end }

local redstone_router = require('nodes.fuel.redstone_router')
local router_ui = require('nodes.fuel.router_ui')

-- A deliberately very long label (installer/valve_naming.lua's clear VALVE
-- names are truncated for display, see router_ui.lua's short_valve_label())
-- must never crash the width math in the VENTILE card or the valve picker
-- (right_w/left_w minus the label length can otherwise go negative).
local comms = {
  get_peers = function()
    return { ['VALVE-1'] = { down = false, role = 'VALVE-NODE', label = 'VALVE-EIN-SEHR-LANGER-KLARNAME-999' } }
  end,
}

local reactors = {
  { reactor_id = 'R1', label = 'Reactor1', inlet = 'inlet_1', path = { 'VALVE-1' }, request_below = 0.25, fill_amount = 64, min_in_me = 32 },
  { reactor_id = 'R2', label = 'Reactor2', inlet = nil, path = {}, request_below = 0.25, fill_amount = 64, min_in_me = 32 },
}

local rs = redstone_router.new({
  config = { logistics = { redstone_tree = {
    { reactor = 'R1', label = 'Reactor1', path = { 'VALVE-1' } },
  } } },
  comms = comms, log = function() end, warn_once = function() end,
})
rs:refresh()

local config = { logistics = { reactors = reactors } }
local ui_page = router_ui.new({
  config = config,
  redstone_router = rs,
  get_reactors = function() return { { reactor_id = 'R1', label = 'Reactor1' }, { reactor_id = 'R3', label = 'Reactor3' } } end,
  log = function() end,
})

local mon = { getSize = function() return 80, 20 end }
local ui_stub = {
  badge = function() end,
  text = function() end,
  getSize = function(t) return t.getSize() end,
}

local function render_ok(label)
  local ok, err = pcall(function() ui_page:render(mon, ui_stub, nil, true) end)
  if not ok then error(label .. ': render() threw: ' .. tostring(err)) end
end

-- 1. "list" -- Hauptbildschirm mit konfigurierten Reaktoren.
render_ok('list view')

-- 2. "learn" -- Reaktor-Einlernen-Picker.
ui_page._ui.mode = 'learn'
render_ok('learn view')

-- 3. "edit" -- Formular fuer einen Reaktor.
ui_page._ui.mode = 'edit'
ui_page._ui.editing = { reactor_id = 'R1', label = 'Reactor1', inlet = 'inlet_1', path = { 'VALVE-1' }, request_below = 0.25, fill_amount = 64, min_in_me = 32 }
render_ok('edit view')

-- 4. "inlet_pick" -- Peripherie-Auswahl.
ui_page._ui.mode = 'inlet_pick'
render_ok('inlet_pick view')

-- 5. "path" -- Ventilketten-Editor, leere Kette.
ui_page._ui.mode = 'path'
ui_page._ui.editing.path = {}
render_ok('path view (empty chain)')

-- 6. "path" mit bestehender Kette.
ui_page._ui.editing.path = { 'VALVE-1' }
render_ok('path view (existing chain)')

print("fuel_router_ui_render_smoke_test.lua: ok")
