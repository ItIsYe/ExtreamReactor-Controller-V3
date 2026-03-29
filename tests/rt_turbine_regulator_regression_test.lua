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
  min = 0,
  max = 2000,
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

local low_flow, low_dir = next_flow(1980, 400, 900)
if not (low_flow == 2000 and low_dir > 0) then
  error('low RPM should clamp up to max flow 2000')
end

local high_flow, high_dir = next_flow(40, 1300, 900)
if not (high_flow == 0 and high_dir < 0) then
  error('high RPM should clamp down to min flow 0')
end

local t1_flow = next_flow(700, 850, 900)
local t2_flow = next_flow(700, 1100, 900)
if t1_flow == t2_flow then
  error('per-turbine RPM inputs must yield individual flow results')
end

print('rt_turbine_regulator_regression_test.lua: ok')
