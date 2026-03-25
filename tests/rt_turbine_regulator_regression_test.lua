package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local regulator = require('core.turbine_regulator')
local rails = require('core.control_rails')

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or 'assert failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local ok, reason = regulator.should_regulate_module_state('RUNNING')
assert_eq(ok, true, 'RUNNING should regulate')
assert_eq(reason, 'STATE_OK', 'RUNNING reason')

local off_ok, off_reason = regulator.should_regulate_module_state('OFF')
assert_eq(off_ok, false, 'OFF should not regulate')
assert_eq(off_reason, 'STATE_OFF', 'OFF reason')

local starting_ok, starting_reason = regulator.should_regulate_module_state('STARTING')
assert_eq(starting_ok, false, 'STARTING should not regulate')
assert_eq(starting_reason, 'STATE_STARTING', 'STARTING reason')

local error_ok, error_reason = regulator.should_regulate_module_state('ERROR')
assert_eq(error_ok, false, 'ERROR should not regulate')
assert_eq(error_reason, 'STATE_ERROR', 'ERROR reason')

if regulator.startup_reached_target(895, 900, 20) ~= true then
  error('startup should become stable when within tolerance')
end
if regulator.startup_reached_target(875, 900, 20) ~= false then
  error('startup must not become stable below tolerance')
end

local flow_cfg = {
  deadband_up = 20,
  deadband_down = 20,
  hysteresis_up = 0,
  hysteresis_down = 0,
  max_step_up = 50,
  max_step_down = 50,
  cooldown_s = 0,
  min = 200,
  max = 1900,
  ema_alpha = 1.0,
}

local function next_flow(current, rpm, target)
  local state = rails.new_state()
  local error = target - rpm
  local flow, direction = rails.step(current, error, state, flow_cfg, os.clock())
  return flow, direction
end

local flow_a, dir_a = next_flow(500, 820, 900)
local flow_b, dir_b = next_flow(500, 980, 900)
if not (flow_a > 500 and dir_a > 0) then
  error('lower RPM turbine should request higher flow')
end
if not (flow_b < 500 and dir_b < 0) then
  error('higher RPM turbine should request lower flow')
end
if flow_a == flow_b then
  error('different RPMs must produce different flow targets')
end

print('rt_turbine_regulator_regression_test.lua: ok')
