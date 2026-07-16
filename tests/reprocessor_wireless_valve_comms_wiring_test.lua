package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer REPROCESSOR-P0 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 20 "KRITISCH OFFEN"). FUEL erzeugt
-- den gemeinsam genutzten redstone_router.lua mit comms=comms, REPROCESSOR
-- erzeugte ihn bisher OHNE comms -- redstone_router.lua's refresh() nutzt
-- self.comms:get_peers(), um einen im Baum konfigurierten Integrator-Namen
-- als per Funk erreichbaren Wireless-VALVE-Node zu erkennen. Ohne comms-
-- Referenz blieb known_peers immer leer, und ein konfigurierter Integrator
-- wurde nur noch als lokales Peripheral gesucht -- ein Wireless-VALVE-
-- Routerbaum konnte fuer REPROCESSOR dadurch als nicht schaltbar enden,
-- obwohl der VALVE-Node im Netzwerk online war.

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function read_file(path)
  local f = assert(io.open(path, 'r'))
  local content = f:read('*a')
  f:close()
  return content
end

-- ---------------------------------------------------------------------
-- 1) Wiring: nodes/reprocessor/main.lua's get_rs_router() muss "comms"
--    tatsaechlich an redstone_router_lib.new() durchreichen, genau wie
--    nodes/fuel/main.lua es bereits tut.
-- ---------------------------------------------------------------------
do
  local source = read_file('xreactor/nodes/reprocessor/main.lua')
  local start_pos = source:find('local function get_rs_router()', 1, true)
  assert_true(start_pos, 'get_rs_router() not found in nodes/reprocessor/main.lua')
  local end_pos = source:find('\nend\n', start_pos, true)
  assert_true(end_pos, 'end of get_rs_router() not found')
  local body = source:sub(start_pos, end_pos)

  assert_true(body:find('redstone_router_lib.new(', 1, true) ~= nil,
    'get_rs_router() must construct redstone_router_lib')
  assert_true(body:find('comms = comms', 1, true) ~= nil,
    'get_rs_router() must pass comms=comms to redstone_router_lib.new() so refresh() can discover wireless VALVE peers via self.comms:get_peers()')
end

-- ---------------------------------------------------------------------
-- 2) Mechanism: without a comms reference, redstone_router.lua's refresh()
--    cannot recognize a configured integrator as a reachable wireless
--    VALVE node -- proves WHY the missing wiring mattered in practice.
-- ---------------------------------------------------------------------
local redstone_router_lib = require('nodes.fuel.redstone_router')

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end, -- no local peripheral fallback either
  wrap = function() return nil end,
}

local function make_tree()
  return { { side = 'top', integrator = 'VALVE-A', reactor = 'R1', label = 'Reactor1' } }
end

do
  -- REPROCESSOR's old (buggy) construction: no comms at all.
  local router_without_comms = redstone_router_lib.new({
    config = { redstone_tree = make_tree() },
    log = function() end,
    warn_once = function() end,
  })
  router_without_comms:refresh()
  assert_true(router_without_comms._state.integrators['VALVE-A'] == nil,
    'without comms, a wireless VALVE integrator must NOT be recognized (reproduces the reported failure mode)')
end

do
  -- FUEL's (and now REPROCESSOR's fixed) construction: comms provided.
  local router_with_comms = redstone_router_lib.new({
    config = { redstone_tree = make_tree() },
    comms = { get_peers = function() return { ['VALVE-A'] = { down = false } } end },
    log = function() end,
    warn_once = function() end,
  })
  router_with_comms:refresh()
  local integrator = router_with_comms._state.integrators['VALVE-A']
  assert_true(integrator ~= nil, 'with comms, the wireless VALVE integrator must be recognized')
  assert_true(integrator.network == true, 'the recognized integrator must be marked as network-reachable (not a local peripheral)')
end

print('reprocessor_wireless_valve_comms_wiring_test.lua: ok')
