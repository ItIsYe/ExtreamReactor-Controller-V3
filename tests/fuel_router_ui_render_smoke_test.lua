package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Smoke test: M:render() darf in KEINEM Modus/Unterzustand einen Lua-
-- Laufzeitfehler werfen (nil-Zugriff, falsche Argumentanzahl etc.) --
-- exercised alle drei sichtbaren Zustaende des neuen mehrstufigen Ventil-
-- ketten-Editors (tree / edit-list / edit-path, inklusive des Zwischen-
-- schritts mit offener Integrator-Auswahl). Nutzt ein minimales Monitor-
-- Mock -- core/mockup_ui.lua's safe_call() toleriert fehlende Methoden
-- bereits (kein Absturz bei einem "nackten" Monitor-Objekt), daher reicht
-- ein Mock, der nur getSize() beantwortet.

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}
_G.redstone = { setOutput = function() end }

local redstone_router = require('nodes.fuel.redstone_router')
local router_ui = require('nodes.fuel.router_ui')

local comms = {
  get_peers = function() return { ['VALVE-1'] = { down = false, role = 'VALVE-NODE' } } end,
}

local routes = {
  { reactor = 'R1', label = 'Reactor1', path = { { side = 'back' }, { side = 'right' } } },
  { reactor = 'R2', label = 'Reactor2', path = { { side = 'back' }, { side = 'left', integrator = 'VALVE-1' } } },
}
local rs = redstone_router.new({
  config = { logistics = { redstone_tree = routes } },
  comms = comms, log = function() end, warn_once = function() end,
})
rs:refresh()

local reactors = { { id = 'R1', label = 'Reactor1' }, { id = 'R2', label = 'Reactor2' } }
local ui_page = router_ui.new({
  redstone_router = rs,
  get_reactors = function() return reactors end,
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

-- 1. TREE-Ansicht (zeigt Routen + Ventilstatus-Panel).
render_ok('tree view')

-- 2. EDIT / LIST-Ansicht (Reaktorliste).
ui_page._ui.mode = 'edit'
ui_page._ui.edit_view = 'list'
render_ok('edit list view')

-- 3. EDIT / PATH-Ansicht, leere Kette, kein pending_side.
ui_page._ui.edit_view = 'path'
ui_page._ui.editing = { reactor = 'R1', label = 'Reactor1', path = {} }
render_ok('edit path view (empty chain)')

-- 4. EDIT / PATH-Ansicht mit bestehender Kette.
ui_page._ui.editing = { reactor = 'R1', label = 'Reactor1', path = { { side = 'back' }, { side = 'left', integrator = 'VALVE-1' } } }
render_ok('edit path view (existing chain)')

-- 5. EDIT / PATH-Ansicht waehrend offener Integrator-Auswahl.
ui_page._ui.pending_side = 'front'
render_ok('edit path view (pending integrator picker)')

print("fuel_router_ui_render_smoke_test.lua: ok")
