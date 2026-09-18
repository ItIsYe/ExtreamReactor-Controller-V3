package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_turbine = require('nodes.rt.rt2_turbine')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- ── compute_target_rpm ───────────────────────────────────────────────────

assert_eq(rt2_turbine.compute_target_rpm("LEARNING", {}), 900, 'LEARNING always targets the fixed RPM')
assert_eq(rt2_turbine.compute_target_rpm("LEARNING", { power_percent = 0 }), 900, 'LEARNING ignores any power_percent input -- unconditional')
assert_eq(rt2_turbine.compute_target_rpm("AUTONOM", { power_percent = 0 }), 900, 'AUTONOM turbines still target the fixed RPM (reactor handles independence, not turbines)')
assert_eq(rt2_turbine.compute_target_rpm("SAFE", {}), 0, 'SAFE targets 0 for every turbine')

-- MASTER split: reproduces the worked examples from the old design doc,
-- now backed by tests instead of only a comment.
do
  -- 50% of 25 turbines: 12 full, 1 partial at 450, 12 off.
  local full, partial, off = 0, 0, 0
  for slot = 1, 25 do
    local target = rt2_turbine.compute_target_rpm("MASTER", { turbine_count = 25, slot_index = slot, power_percent = 50 })
    if target == 900 then full = full + 1
    elseif target == 0 then off = off + 1
    else partial = partial + 1; assert_eq(target, 450, 'the single partial turbine must target exactly half RPM at 50%') end
  end
  assert_eq(full, 12, '50% of 25 turbines: 12 full-load turbines expected')
  assert_eq(partial, 1, '50% of 25 turbines: exactly one partial turbine expected')
  assert_eq(off, 12, '50% of 25 turbines: 12 off turbines expected')
end

-- Single-turbine fleet must still scale with power_percent (regression:
-- the old n<=1 shortcut ignored power_percent entirely and always
-- returned the full 900 RPM).
assert_eq(rt2_turbine.compute_target_rpm("MASTER", { turbine_count = 1, slot_index = 1, power_percent = 20 }), 180, 'single turbine at 20% must target 180 RPM')
assert_eq(rt2_turbine.compute_target_rpm("MASTER", { turbine_count = 1, slot_index = 1, power_percent = 50 }), 450, 'single turbine at 50% must target 450 RPM')
assert_eq(rt2_turbine.compute_target_rpm("MASTER", { turbine_count = 1, slot_index = 1, power_percent = 100 }), 900, 'single turbine at 100% must target the full RPM')

-- ── compute_flow_decision ────────────────────────────────────────────────

-- Regression: an AUS-slot turbine (target_rpm=0) spinning at thousands of
-- RPM must be forced to flow=0 immediately -- this was the exact bug
-- reported 2026-09-18 (node-101/102/103: STATUS=OFF turbines sitting on
-- 2.0k-3.0k flow at 1000-3200 RPM while the "ON" ones correctly throttled).
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 2866, target_rpm = 0, current_flow = 20000, max_flow = 32000 })
  assert_eq(d.flow, 0, 'AUS-slot turbine massively overspeeding must be forced to flow=0 immediately, not ramped down')
  assert_eq(d.reason, 'TARGET_ZERO', 'reason must reflect the target-zero rule, not a generic ramp')
end

-- A real overspeed case (positive target, RPM far above it) must also be
-- forced to 0 immediately -- same outcome, different reason, so a caller
-- can tell "parked" apart from "braking" if it needs to (e.g. for coil
-- engagement decisions elsewhere).
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 2000, target_rpm = 900, current_flow = 20000, max_flow = 32000 })
  assert_eq(d.flow, 0, 'genuine overspeed must be forced to flow=0')
  assert_eq(d.reason, 'OVERSPEED', 'reason must reflect genuine overspeed, distinct from TARGET_ZERO')
end

-- Well under target: ramp up, not directly to max.
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 100, target_rpm = 900, current_flow = 5000, max_flow = 32000 })
  assert_true(d.flow > 5000 and d.flow < 32000, 'well under target must ramp up gradually, not jump to max')
end

-- Inside the band: small trims only, never a big jump.
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 905, target_rpm = 900, current_flow = 5000, band = 30 })
  assert_true(math.abs(d.flow - 5000) <= 1, 'inside the band, flow must only trim by a small step')
end

-- ── compute_coil_decision ────────────────────────────────────────────────

assert_eq(rt2_turbine.compute_coil_decision({ rpm = 2000, target_rpm = 0, currently_engaged = true }).engaged, false, 'target_rpm<=0 must always disengage the coil')

-- A PUFFER-slot turbine at 450 RPM target must engage/disengage scaled to
-- 450, not the full 900 -- otherwise it would never appear to reach target.
do
  local d = rt2_turbine.compute_coil_decision({ rpm = 450, target_rpm = 450, currently_engaged = false })
  assert_eq(d.engaged, true, 'a 450 RPM-target turbine at 450 RPM must engage (scaled threshold)')
end

do
  local d = rt2_turbine.compute_coil_decision({ rpm = 400, target_rpm = 900, currently_engaged = false })
  assert_eq(d.engaged, false, 'the same 400 RPM must NOT engage against a 900 RPM target (unscaled would wrongly hold this near the 450 case)')
end

print('rt2_turbine_test.lua: ok')
