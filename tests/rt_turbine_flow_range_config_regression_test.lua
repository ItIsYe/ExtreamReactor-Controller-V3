local function assert_true(value, message)
  if not value then
    error(message or 'assert_true failed')
  end
end

local file = io.open('xreactor/nodes/rt/main.lua', 'r')
if not file then
  error('failed to open RT main source')
end
local content = file:read('*a')
file:close()

assert_true(content:find('data%.min = safety%.clamp%(data%.min, MIN_FLOW, MAX_FLOW%)') ~= nil,
  'turbine rail min must be clamped to runtime MIN_FLOW/MAX_FLOW')
assert_true(content:find('data%.max = safety%.clamp%(data%.max, MIN_FLOW, MAX_FLOW%)') ~= nil,
  'turbine rail max must be clamped to runtime MIN_FLOW/MAX_FLOW')
assert_true(content:find('MIN_FLOW = 0', 1, true) ~= nil,
  'runtime minimum turbine flow must stay at 0')
assert_true(content:find('MAX_FLOW = 2000', 1, true) ~= nil,
  'runtime maximum turbine flow must stay at 2000')
assert_true(content:find('START_FLOW = 0', 1, true) ~= nil,
  'startup turbine flow must allow direct ramp from 0')
assert_true(content:find('data%.adaptive_step = data%.adaptive_step ~= false') ~= nil,
  'turbine rail adaptive_step default must stay enabled')
assert_true(content:find('reason=', 1, true) ~= nil,
  'turbine debug log must include reason field')
assert_true(content:find('clamp_min=', 1, true) ~= nil,
  'turbine debug log must include effective clamp min')
assert_true(content:find('clamp_max=', 1, true) ~= nil,
  'turbine debug log must include effective clamp max')
assert_true(content:find('decision and decision.reason == "DEADBAND" and base_flow >= %(max_flow %- 1%)') ~= nil,
  'rt control loop must actively trim down at max flow instead of HOLD/DEADBAND')
assert_true(content:find('confirmed_at_max', 1, true) ~= nil,
  'rt control loop must track confirmed max-flow readback for target-band trim decisions')
assert_true(content:find('decision.reason = "TARGET_TRIM_DOWN"', 1, true) ~= nil,
  'rt control loop must force target-band trim down instead of passive hold at max flow')

print('rt_turbine_flow_range_config_regression_test.lua: ok')
