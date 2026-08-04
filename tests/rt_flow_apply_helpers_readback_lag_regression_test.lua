package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local helpers   = require('nodes.rt.flow_apply_helpers')
local regulator = require('core.turbine_regulator')
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or 'assert failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

-- Szenario: write 1200, Turbine läuft noch auf 1300
-- settle_timeout_s=0.8 → stage = floor(age/0.8)
local ctrl = {
  pending_expected_flow=1300, pending_flow_since=10.0,
  pending_retries=0, pending_retry_stage=0,
  effective_min_hits=0, effective_min_flow=nil, overspeed_floor_hits=0
}
local rail_cfg = { settle_timeout_s=0.8, readback_retry_cap=3, effective_min_samples=3 }

-- Aufruf 1: neue Write 1200, pending_flow_since→10.3, pending_expected→1200
-- flows_match(1200,1300,1)=false → pending_settled=false
local s1 = helpers.update_turbine_flow_tracking(
  ctrl, 1200, 1300, 1, rail_cfg, 10.3, {reason='TARGET_TRIM_DOWN'}, 'WRITE_ACCEPTED', regulator)
assert_eq(s1, false, 'first down-write should remain pending')
assert_eq(ctrl.pending_retries, 0, 'retry counter must not increment within settle timeout window')
assert_eq(ctrl.pending_retry_stage, 0, 'retry stage must stay zero before timeout boundary')

-- Aufruf 2: same flow 1200, confirmed=1300, now=11.2 → age=11.2-10.3=0.9 → stage=1
helpers.update_turbine_flow_tracking(
  ctrl, 1200, 1300, 1, rail_cfg, 11.2, {reason='READBACK_SETTLING_HOLD'}, 'WRITE_ACCEPTED', regulator)
assert_eq(ctrl.pending_retries, 1, 'retry counter should increment once after one settle timeout window')
assert_eq(ctrl.pending_retry_stage, 1, 'retry stage should track elapsed settle windows')

-- Aufruf 3: now=12.0 → age=12.0-10.3=1.7 → stage=2
helpers.update_turbine_flow_tracking(
  ctrl, 1200, 1300, 1, rail_cfg, 12.0, {reason='READBACK_SETTLING_HOLD'}, 'WRITE_ACCEPTED', regulator)
assert_eq(ctrl.pending_retries, 2, 'retry counter should advance one step per extra settle timeout window')
assert_eq(ctrl.pending_retry_stage, 2, 'retry stage should be monotonic with pending age')

-- Aufruf 4+5: confirmed=1200 (settled!) → retries reset
helpers.update_turbine_flow_tracking(
  ctrl, 1200, 1200, 1, rail_cfg, 12.1, {reason='TRACKING'}, 'WRITE_ACCEPTED', regulator)
local s5 = helpers.update_turbine_flow_tracking(
  ctrl, 1200, 1200, 1, rail_cfg, 12.2, {reason='TRACKING'}, 'WRITE_ACCEPTED', regulator)
assert_eq(s5, true, 'confirmed match should be settled')
assert_eq(ctrl.pending_retries, 0, 'retries must reset after confirmation')

print('rt_flow_apply_helpers_readback_lag_regression_test.lua: ok')
