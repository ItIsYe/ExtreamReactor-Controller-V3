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

assert_true(content:find('local function adjust_turbines%(') ~= nil, 'adjust_turbines function missing in RT main')
assert_true(content:find('local function adjust_reactors%(') ~= nil, 'adjust_reactors function missing in RT main')
assert_true(content:find('adjust_turbines = adjust_turbines', 1, true) ~= nil, 'state context must wire adjust_turbines')
assert_true(content:find('adjust_reactors = adjust_reactors', 1, true) ~= nil, 'state context must wire adjust_reactors')

print('rt_control_tick_wiring_regression_test.lua: ok')
