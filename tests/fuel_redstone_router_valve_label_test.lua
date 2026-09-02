package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test: get_valve_status() now surfaces the VALVE's clear
-- display name (installer/valve_naming.lua, carried over the network via
-- core/comms.lua's peer.label -- see tests/comms_peer_label_test.lua for
-- the wire path) so router_ui.lua can show it instead of the raw node_id.
-- id (the stable key stored in fuel_routes.lua) must stay untouched --
-- only a separate "label" field is added, purely for display.

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}

local redstone_router = require('nodes.fuel.redstone_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local routes = {
  { reactor = 'R1', label = 'Reactor1', path = { { side = 'back', integrator = 'VALVE-1' } } },
  { reactor = 'R2', label = 'Reactor2', path = { { side = 'left', integrator = 'VALVE-2' } } },
}

-- VALVE-1 has a clear name from the network; VALVE-2 has none yet (e.g. an
-- older node that hasn't run the new installer step) -- must fall back to
-- its raw id, never render a blank/nil label.
local comms = {
  get_peers = function()
    return {
      ['VALVE-1'] = { down = false, role = 'VALVE-NODE', label = 'Nordtrakt-Sortierer' },
      ['VALVE-2'] = { down = false, role = 'VALVE-NODE' },
    }
  end,
}

local rs = redstone_router.new({
  config = { logistics = { redstone_tree = routes } },
  comms = comms, log = function() end, warn_once = function() end,
})
rs:refresh()

local status = rs:get_valve_status()
local by_id = {}
for _, vs in ipairs(status) do by_id[vs.id] = vs end

assert_eq(by_id['VALVE-1'].label, 'Nordtrakt-Sortierer', 'a labeled VALVE must show its clear name')
assert_eq(by_id['VALVE-1'].id, 'VALVE-1', 'id must stay the stable routing key, unaffected by the label')
assert_eq(by_id['VALVE-2'].label, 'VALVE-2', 'an unlabeled VALVE must fall back to its raw id, not nil/blank')

print("fuel_redstone_router_valve_label_test.lua: ok")
