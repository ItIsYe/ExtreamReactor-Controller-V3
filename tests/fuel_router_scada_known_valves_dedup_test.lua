package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (user report 2026-09-14: "leichte Performance-Probleme"
-- on FUEL with ~20 active VALVE nodes). router_scada.lua's known_valves()
-- rebuilds+sorts the full valve list from a fresh comms:get_peers()
-- snapshot -- draw_path() (the VENTILKETTE / route chain editor) used to
-- call it once per visible path row (via valve_label()) PLUS once more for
-- the picker list, i.e. up to PATH_VISIBLE+1 = 8 full rebuilds per single
-- render. Now fetched once per render and reused.

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
  getNames = function() return {} end,
}
_G.redstone = { setOutput = function() end }

local get_peers_calls = 0
local peers = {}
for i = 1, 20 do
  peers['VALVE-' .. i] = { down = false, role = 'VALVE-NODE', label = 'Valve ' .. i }
end
local comms = {
  get_peers = function()
    get_peers_calls = get_peers_calls + 1
    return peers
  end,
}

local redstone_router = require('nodes.fuel.redstone_router')
local router_ui = require('nodes.fuel.router_ui')

local reactors = {
  { reactor_id = 'R1', label = 'Reactor1', path = { 'VALVE-1', 'VALVE-2', 'VALVE-3', 'VALVE-4', 'VALVE-5', 'VALVE-6', 'VALVE-7', 'VALVE-8' },
    request_below = 0.25, fill_amount = 64, min_in_me = 32 },
}

local rs = redstone_router.new({
  config = { logistics = { redstone_tree = {} } },
  comms = comms, log = function() end, warn_once = function() end,
})
rs:refresh()

local page = router_ui.new({
  config = { logistics = { reactors = reactors } },
  redstone_router = rs,
  get_reactors = function() return {} end,
  log = function() end,
})

local mon = { getSize = function() return 82, 40 end }
local ui_stub = { getSize = function(target) return target.getSize() end }

page._ui.mode = 'path'
page._ui.editing = reactors[1]

get_peers_calls = 0
page:render(mon, ui_stub, nil, true)

if get_peers_calls ~= 1 then
  error('draw_path() must fetch the valve peer list exactly once per render (known_valves() reused for both the path rows and the picker list), got ' .. get_peers_calls .. ' calls')
end

print('fuel_router_scada_known_valves_dedup_test.lua: ok')
