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
  max_step_up = 250,
  max_step_down = 250,
  min_step_up = 50,
  min_step_down = 50,
  step_per_rpm_up = 0.5,
  step_per_rpm_down = 0.5,
  adaptive_step = true,
  cooldown_s = 0,
  min = 0,
  max = 2000,
  ema_alpha = 1.0,
}

local function next_flow(current, rpm, target)
  local state = rails.new_state()
  local error = target - rpm
  local flow, direction, decision = rails.step(current, error, state, flow_cfg, os.clock())
  return flow, direction, decision
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

local small_error_flow = next_flow(1000, 890, 900)
if small_error_flow ~= 1000 then
  error('RPM within deadband should hold flow')
end

local medium_step_flow, _, medium_decision = next_flow(500, 760, 900) -- +140 rpm error
if medium_step_flow ~= 570 then
  error('adaptive step should use proportional delta for medium RPM error')
end
if not (medium_decision and medium_decision.step == 70) then
  error('decision metadata must expose applied adaptive step')
end

local huge_step_flow, _, huge_decision = next_flow(500, 0, 900)
if huge_step_flow ~= 750 then
  error('adaptive step should be capped at max_step_up')
end
if not (huge_decision and huge_decision.step == 250) then
  error('decision metadata should show capped step')
end

local start_flow = regulator.clamp_flow(nil, 0, 2000)
if start_flow ~= 0 then
  error('startup fallback flow must clamp to lower bound 0')
end

if regulator.flows_match(0, 200, 1) then
  error('requested and confirmed flow must not match when delta exceeds tolerance')
end
if not regulator.flows_match(200, 201, 1) then
  error('flow match should allow tolerance window')
end

local defer_a, reason_a = regulator.should_defer_cooldown(0, 200, 10.0, 10.2, 0.8, 1)
if not defer_a or reason_a ~= 'WAITING_CONFIRM' then
  error('cooldown should defer while flow change is pending confirmation')
end

local defer_b, reason_b = regulator.should_defer_cooldown(0, 200, 10.0, 11.1, 0.8, 1)
if defer_b or reason_b ~= 'SETTLE_TIMEOUT' then
  error('cooldown defer should end after settle timeout')
end

local defer_c, reason_c = regulator.should_defer_cooldown(500, 500, 10.0, 10.1, 0.8, 1)
if defer_c or reason_c ~= 'SETTLED' then
  error('cooldown must not defer for settled flow values')
end

local defer_d, reason_d = regulator.should_defer_cooldown(0, 200, nil, 5.0, 0.8, 1)
if not defer_d or reason_d ~= 'WAITING_CONFIRM' then
  error('cooldown defer must handle missing pending timestamp during readback lag')
end

local tracker = { effective_min_hits = 0, effective_min_flow = nil }
local m1, changed1 = regulator.update_effective_min(tracker, 0, 200, 3)
local m2, changed2 = regulator.update_effective_min(tracker, 0, 200, 3)
local m3, changed3 = regulator.update_effective_min(tracker, 0, 200, 3)
if m1 ~= nil or changed1 then
  error('effective minimum must not be confirmed after one sample')
end
if m2 ~= nil or changed2 then
  error('effective minimum must not be confirmed before required samples')
end
if m3 ~= 200 or not changed3 then
  error('effective minimum must be confirmed after required repeated samples')
end

local m4, changed4 = regulator.update_effective_min(tracker, 0, 200, 3)
if m4 ~= 200 or changed4 then
  error('effective minimum should stay stable without re-triggering change signal')
end

local m5, changed5 = regulator.update_effective_min(tracker, 300, 300, 3)
if m5 ~= 200 or changed5 then
  error('effective minimum should persist per turbine after non-zero requests')
end

local tracker_a = { effective_min_hits = 0, effective_min_flow = nil }
local tracker_b = { effective_min_hits = 0, effective_min_flow = nil }
local tracker_c = { effective_min_hits = 0, effective_min_flow = nil }
for _ = 1, 3 do
  regulator.update_effective_min(tracker_a, 0, 200, 3)
  regulator.update_effective_min(tracker_b, 0, 250, 3)
  regulator.update_effective_min(tracker_c, 0, 313, 3)
end
if tracker_a.effective_min_flow ~= 200 or tracker_b.effective_min_flow ~= 250 or tracker_c.effective_min_flow ~= 313 then
  error('per-turbine effective minimums must remain independent (200/250/313)')
end

local resolved_min_a, used_effective_a = regulator.resolve_min_flow(0, 200)
if resolved_min_a ~= 200 or not used_effective_a then
  error('effective minimum should raise clamp minimum per turbine')
end

local resolved_min_b, used_effective_b = regulator.resolve_min_flow(200, 1)
if resolved_min_b ~= 200 or used_effective_b then
  error('base minimum should win when effective minimum is lower')
end

local target_trim_down = regulator.target_band_state({
  rpm = 900,
  live_rpm = 904,
  target_rpm = 900,
  requested_flow = 2000,
  confirmed_flow = 2000,
  min_flow = 200,
  max_flow = 2000,
  coil_engaged = true,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50
})
if not target_trim_down.in_band then
  error('target band should be active near 900 RPM')
end
if target_trim_down.reason ~= 'TARGET_TRIM_DOWN' or target_trim_down.direction ~= -1 then
  error('in-target max-flow state must actively trim down instead of hold/deadband')
end
if target_trim_down.flow >= 2000 then
  error('target trim down must reduce flow below hard max 2000')
end

local startup_state = {
  startup_synced = false,
  requested_flow = 0,
  confirmed_flow = 0,
  flow = 0,
  pending_expected_flow = 0,
  pending_flow_since = 5,
  pending_retries = 3,
}
local synced = regulator.sync_startup_state(startup_state, 2000)
if not synced then
  error('startup state sync should succeed with numeric confirmed flow')
end
if startup_state.confirmed_flow ~= 2000
    or startup_state.requested_flow ~= 2000
    or startup_state.flow ~= 2000
    or startup_state.pending_expected_flow ~= 2000
    or startup_state.pending_flow_since ~= 0
    or startup_state.pending_retries ~= 0
    or startup_state.last_requested_flow ~= 2000
    or startup_state.startup_synced ~= true then
  error('startup state sync must align internal flow fields with confirmed flow')
end



local bottleneck_a, detail_a = regulator.classify_bottleneck({
  requested_flow = 2000,
  confirmed_flow = 2000,
  rpm = 500,
  target_rpm = 900,
  max_flow = 2000,
  inductor_engaged = false,
  steam_input = 1800,
})
if bottleneck_a ~= 'MAX_FLOW_LOW_RPM_STEAM_LIMIT' then
  error('max flow with low rpm and coil disabled should classify steam limit')
end
if detail_a ~= 'STEAM_INPUT_BELOW_FLOW' then
  error('steam-limited bottleneck should include explicit detail')
end

local bottleneck_b, detail_b = regulator.classify_bottleneck({
  requested_flow = 2000,
  confirmed_flow = 2000,
  rpm = 500,
  target_rpm = 900,
  max_flow = 2000,
  inductor_engaged = true,
})
if bottleneck_b ~= 'MAX_FLOW_LOW_RPM_WITH_COIL' then
  error('max flow with low rpm and coil enabled should classify coil load')
end
if detail_b ~= 'PLANT_OR_COIL_LIMIT' then
  error('coil bottleneck should include plant/coil detail')
end

local bottleneck_c, detail_c = regulator.classify_bottleneck({
  requested_flow = 1000,
  confirmed_flow = 900,
  rpm = 900,
  target_rpm = 900,
  max_flow = 2000,
  inductor_engaged = true,
})
if bottleneck_c ~= 'FLOW_READBACK_LAG' then
  error('flow mismatch should classify readback lag')
end
if detail_c ~= 'API_READBACK_LAG' then
  error('readback lag should include API detail')
end

local bottleneck_d, detail_d = regulator.classify_bottleneck({
  requested_flow = 250,
  confirmed_flow = 250,
  rpm = 980,
  target_rpm = 900,
  min_flow = 250,
  max_flow = 2000,
  inductor_engaged = true,
})
if bottleneck_d ~= 'MIN_LIMIT_OVERSPEED' then
  error('effective minimum overspeed should classify minimum-limit bottleneck')
end
if detail_d ~= 'MIN_FLOW_WITH_COIL_ENGAGED_NO_FURTHER_DOWN' then
  error('minimum-limit bottleneck should expose coil contribution detail')
end

local hold_state = regulator.target_band_state({
  rpm = 901,
  target_rpm = 900,
  requested_flow = 1200,
  min_flow = 200,
  max_flow = 2000,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50
})
if not hold_state.in_band or hold_state.mode ~= 'HOLDING_TARGET_ACTIVE' or hold_state.flow ~= 1200 then
  error('target-band hold should keep flow steady when within trim deadzone')
end
if hold_state.reason ~= 'TARGET_BAND_ACTIVE' then
  error('target-band hold should expose active hold reason')
end

local hold_state_with_coil = regulator.target_band_state({
  rpm = 901,
  target_rpm = 900,
  requested_flow = 1200,
  min_flow = 200,
  max_flow = 2000,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50,
  coil_engaged = true
})
if hold_state_with_coil.reason ~= 'TARGET_BAND_ACTIVE_WITH_COIL' then
  error('target-band hold should expose coil-aware active hold reason')
end

local hold_state_live_override = regulator.target_band_state({
  rpm = 860,
  live_rpm = 902,
  target_rpm = 900,
  requested_flow = 1200,
  min_flow = 200,
  max_flow = 2000,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50
})
if not hold_state_live_override.in_band or hold_state_live_override.mode ~= 'HOLDING_TARGET_ACTIVE' then
  error('live RPM inside target band should keep active holding even when smoothed rpm lags')
end

local trim_down_state = regulator.target_band_state({
  rpm = 915,
  target_rpm = 900,
  requested_flow = 2000,
  min_flow = 200,
  max_flow = 2000,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50
})
if trim_down_state.mode ~= 'TARGET_TRIM_DOWN' or trim_down_state.flow ~= 1950 then
  error('target-band overspeed at max flow should trim down instead of passive hold')
end
if trim_down_state.at_min_limit then
  error('target trim down from high flow should not report min-limit clamp')
end

local trim_up_state = regulator.target_band_state({
  rpm = 892,
  target_rpm = 900,
  requested_flow = 900,
  min_flow = 200,
  max_flow = 2000,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50
})
if trim_up_state.mode ~= 'TARGET_TRIM_UP' or trim_up_state.flow ~= 925 then
  error('target-band underspeed should trim flow up')
end
if trim_up_state.at_max_limit then
  error('target trim up at mid-flow should not report max-limit clamp')
end

local max_escape_state = regulator.target_band_state({
  rpm = 898,
  target_rpm = 900,
  requested_flow = 2000,
  min_flow = 200,
  max_flow = 2000,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50
})
if max_escape_state.mode ~= 'TARGET_TRIM_DOWN' or max_escape_state.flow ~= 1950 then
  error('target-band near-target at max flow should trim down to avoid passive hold at 2000')
end

local confirmed_max_trim_state = regulator.target_band_state({
  rpm = 900,
  target_rpm = 900,
  requested_flow = 1950,
  confirmed_flow = 2000,
  min_flow = 200,
  max_flow = 2000,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50
})
if confirmed_max_trim_state.mode ~= 'TARGET_TRIM_DOWN' or confirmed_max_trim_state.flow ~= 1900 then
  error('target-band should trim down when confirmed flow is still at max to avoid HOLD+2000')
end

local coil_max_trim_state = regulator.target_band_state({
  rpm = 900,
  target_rpm = 900,
  requested_flow = 2000,
  confirmed_flow = 2000,
  min_flow = 313,
  max_flow = 2000,
  band_rpm = 30,
  trim_trigger_rpm = 6,
  trim_up_step = 25,
  trim_down_step = 50,
  coil_engaged = true
})
if coil_max_trim_state.mode ~= 'TARGET_TRIM_DOWN' or coil_max_trim_state.flow ~= 1950 then
  error('coil-engaged target-band must still trim down at max flow to avoid HOLD+2000')
end

print('rt_turbine_regulator_regression_test.lua: ok')
