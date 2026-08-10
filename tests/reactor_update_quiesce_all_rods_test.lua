package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local function reset_modules()
  package.loaded['core.utils'] = nil
  package.loaded['adapters.reactor'] = nil
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_false(v, m) if v then error(m or 'assert_false failed') end end

-- 19 rods at 100 and one rod at 90 average to 99.5. The old quiesce path
-- accepted the average; the new actuator contract must reject the open rod.
reset_modules()
local levels = {}
for i = 1, 19 do levels[i] = 100 end
levels[20] = 90
_G.peripheral = {
  isPresent = function() return true end,
  getMethods = function() return { 'setAllControlRodLevels', 'getControlRodsLevels' } end,
  call = function(_, method)
    if method == 'setAllControlRodLevels' then return true end
    if method == 'getControlRodsLevels' then return levels end
    return true
  end,
}
local reactor = require('adapters.reactor')
local ok, err = reactor.apply_rod_level('reactor_0', 100, 'TEST')
assert_false(ok == true, '100% write must fail when any rod readback is below safe threshold')
assert_true(tostring(err):find('minimum rod', 1, true) ~= nil, 'failure should identify minimum rod readback')

-- Complete 100% readback succeeds.
reset_modules()
levels = { 100, 100, 100, 100 }
_G.peripheral = {
  isPresent = function() return true end,
  getMethods = function() return { 'setAllControlRodLevels', 'getControlRodsLevels' } end,
  call = function(_, method)
    if method == 'setAllControlRodLevels' then return true end
    if method == 'getControlRodsLevels' then return levels end
    return true
  end,
}
reactor = require('adapters.reactor')
ok, err = reactor.apply_rod_level('reactor_0', 100, 'TEST')
assert_true(ok == true, 'complete 100% rod readback must be accepted: ' .. tostring(err))

-- A partial indexed write is not a whole-reactor success.
reset_modules()
_G.peripheral = {
  isPresent = function() return true end,
  getMethods = function() return { 'setControlRodLevel', 'getControlRodsLevels' } end,
  call = function(_, method, index)
    if method == 'getControlRodsLevels' then return { 50, 50, 50 } end
    if method == 'setControlRodLevel' then return index ~= 1 end
    return true
  end,
}
reactor = require('adapters.reactor')
ok = reactor.apply_rod_level('reactor_0', 75, 'TEST')
assert_false(ok == true, 'partial indexed rod write must not be reported as successful')

print('reactor_update_quiesce_all_rods_test.lua: ok')
