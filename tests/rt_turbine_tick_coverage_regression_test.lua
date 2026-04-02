local file = assert(io.open('xreactor/nodes/rt/main.lua', 'r'))
local content = file:read('*a')
file:close()

local function assert_has(snippet, message)
  if not content:find(snippet, 1, true) then
    error(message .. ' missing snippet=' .. snippet)
  end
end

assert_has('TurbineTick evaluated=', 'tick summary logging')
assert_has('decisions=', 'tick summary decision count')
assert_has('skip_reasons=', 'tick summary skip reason count')
assert_has('INDUCTOR_UPDATE_FAILED_NONFATAL', 'inductor failures should no longer stop flow regulation')
assert_has('SET_ACTIVE_FAILED_NONFATAL', 'activation failures should no longer stop flow regulation')
assert_has('OVERSPEED_BRAKE_FLOW_ZERO', 'overspeed must force flow to zero')
assert_has('enforce_overspeed_brake_coil', 'overspeed must enforce coil braking')

print('rt_turbine_tick_coverage_regression_test.lua: ok')
