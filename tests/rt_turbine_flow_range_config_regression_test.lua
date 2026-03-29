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
assert_true(content:find('data%.adaptive_step = data%.adaptive_step ~= false') ~= nil,
  'turbine rail adaptive_step default must stay enabled')
assert_true(content:find('reason=', 1, true) ~= nil,
  'turbine debug log must include reason field')
assert_true(content:find('clamp_min=', 1, true) ~= nil,
  'turbine debug log must include effective clamp min')
assert_true(content:find('clamp_max=', 1, true) ~= nil,
  'turbine debug log must include effective clamp max')

print('rt_turbine_flow_range_config_regression_test.lua: ok')
