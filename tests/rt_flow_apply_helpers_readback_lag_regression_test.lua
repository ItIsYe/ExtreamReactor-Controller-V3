package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local helpers = require('nodes.rt.flow_apply_helpers')
local regulator = require('core.turbine_regulator')

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or 'assert failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local ctrl = {
  pending_expected_flow = 1300,
  pending_flow_since = 10.0,
  pending_retries = 0,
  pending_retry_stage = 0,
  effective_min_hits = 0,
  effective_min_flow = nil,
  overspeed_floor_hits = 0
}

local rail_cfg = {
  settle_timeout_s = 0.8,
  readback_retry_cap = 3,
  effective_min_samples = 3,
}

local pending_settled_a = helpers.update_turbine_flow_tracking(
  ctrl,
  1200,
  1300,
  1,
  rail_cfg,
  10.3,
  { reason = 'TARGET_TRIM_DOWN' },
  'WRITE_ACCEPTED',
  regulator
)
assert_eq(pending_settled_a, false, 'first down-write should remain pending')
assert_eq(ctrl.pending_retries, 0, 'retry counter must not increment within settle timeout window')
assert_eq(ctrl.pending_retry_stage, 0, 'retry stage must stay zero before timeout boundary')

helpers.update_turbine_flow_tracking(
  ctrl,
  1200,
  1300,
  1,
  rail_cfg,
  10.9,
  { reason = 'READBACK_SETTLING_HOLD' },
  'WRITE_ACCEPTED',
  regulator
)
assert_eq(ctrl.pending_retries, 1, 'retry counter should increment once after one settle timeout window')
assert_eq(ctrl.pending_retry_stage, 1, 'retry stage should track elapsed settle windows')

helpers.update_turbine_flow_tracking(
  ctrl,
  1200,
  1300,
  1,
  rail_cfg,
  11.7,
  { reason = 'READBACK_SETTLING_HOLD' },
  'WRITE_ACCEPTED',
  regulator
)
assert_eq(ctrl.pending_retries, 2, 'retry counter should advance one step per extra settle timeout window')
assert_eq(ctrl.pending_retry_stage, 2, 'retry stage should be monotonic with pending age')

helpers.update_turbine_flow_tracking(
  ctrl,
  1200,
  1200,
  1,
  rail_cfg,
  12.0,
  { reason = 'TRACKING' },
  'WRITE_ACCEPTED',
  regulator
)
assert_eq(ctrl.pending_retries, 0, 'retry counter must reset when pending write settles')
assert_eq(ctrl.pending_retry_stage, 0, 'retry stage must reset when pending write settles')
assert_eq(ctrl.pending_flow_since, 0, 'pending timestamp must clear after settle')

print('rt_flow_apply_helpers_readback_lag_regression_test.lua: ok')
