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
  local d = rt2_turbine.compute_flow_decision({ rpm = 2866, target_rpm = 0, current_flow = 2000, max_flow = 2000 })
  assert_eq(d.flow, 0, 'AUS-slot turbine massively overspeeding must be forced to flow=0 immediately, not ramped down')
  assert_eq(d.reason, 'TARGET_ZERO', 'reason must reflect the target-zero rule, not a generic ramp')
end

-- A real overspeed case (positive target, RPM far above it) must also be
-- forced to 0 immediately -- same outcome, different reason, so a caller
-- can tell "parked" apart from "braking" if it needs to (e.g. for coil
-- engagement decisions elsewhere).
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 2000, target_rpm = 900, current_flow = 2000, max_flow = 2000 })
  assert_eq(d.flow, 0, 'genuine overspeed must be forced to flow=0')
  assert_eq(d.reason, 'OVERSPEED', 'reason must reflect genuine overspeed, distinct from TARGET_ZERO')
end

-- The overspeed cut is an ABSOLUTE machine limit, not a margin on top of
-- the target: a PUFFER-slot turbine holding 450 has exactly the same
-- physical limit as one at full load. Getting back down to the target is
-- RAMP_DOWN's job, so everything between the band and the limit ramps.
do
  local limit = rt2_turbine.OVERSPEED_RPM
  for _, target in ipairs({ 900, 450, 180 }) do
    local below = rt2_turbine.compute_flow_decision({ rpm = limit - 1, target_rpm = target, current_flow = 1000 })
    assert_eq(below.reason, 'RAMP_DOWN', 'below the machine limit a turbine ramps down toward target ' .. target)
    local above = rt2_turbine.compute_flow_decision({ rpm = limit + 1, target_rpm = target, current_flow = 1000 })
    assert_eq(above.reason, 'OVERSPEED', 'the same absolute limit applies at target ' .. target)
    assert_eq(above.flow, 0)
  end
end

-- The RAMP_DOWN branch must stay reachable. It was dead code once before:
-- the overspeed cut fired at target+band, which is the exact condition of
-- the RAMP_DOWN test below it, so the cut always won and the turbine had
-- no proportional downward control at all.
do
  local reached = {}
  for rpm = 0, 3000 do
    reached[rt2_turbine.compute_flow_decision({ rpm = rpm, target_rpm = 900, current_flow = 1000 }).reason] = true
  end
  assert_true(reached.RAMP_DOWN, 'RAMP_DOWN must be reachable -- the overspeed cut must not swallow it')
  assert_true(reached.RAMP_UP and reached.HOLD_TRIM_UP and reached.HOLD_TRIM_DOWN and reached.OVERSPEED,
    'every other flow branch must stay reachable too')
end

-- Well under target: ramp up, not directly to max.
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 100, target_rpm = 900, current_flow = 500, max_flow = 2000 })
  assert_true(d.flow > 500 and d.flow < 2000, 'well under target must ramp up gradually, not jump to max')
end

-- Inside the band: small trims only, never a big jump.
do
  local d = rt2_turbine.compute_flow_decision({ rpm = 905, target_rpm = 900, current_flow = 1200, band = 30 })
  assert_true(math.abs(d.flow - 1200) <= 1, 'inside the band, flow must only trim by a small step')
end

-- ── compute_coil_decision ────────────────────────────────────────────────

-- The coil is the brake, so a parked turbine that is STILL SPINNING keeps
-- it engaged: that slows the rotor down and harvests the energy on the way
-- instead of letting it coast. It only releases once basically stopped.
do
  local spinning = rt2_turbine.compute_coil_decision({ rpm = 2000, target_rpm = 0, currently_engaged = true })
  assert_eq(spinning.engaged, true, 'a parked turbine that still spins must brake through its coil, not coast')
  assert_eq(spinning.reason, 'BRAKE_TO_STOP')

  local stopped = rt2_turbine.compute_coil_decision({ rpm = 10, target_rpm = 0, currently_engaged = true })
  assert_eq(stopped.engaged, false, 'once stopped there is nothing left to brake or harvest')
  assert_eq(stopped.reason, 'STOPPED')
end

-- Braking toward a LOWER target must couple too, even from uncoupled --
-- waiting for the engage threshold there would mean coasting exactly when
-- braking is wanted.
do
  local d = rt2_turbine.compute_coil_decision({ rpm = 900, target_rpm = 450, currently_engaged = false })
  assert_eq(d.engaged, true, 'a turbine well above a lowered target must couple to brake down to it')
  assert_eq(d.reason, 'BRAKE_TO_TARGET')
end

-- Spinning UP must stay uncoupled so the rotor can accelerate unloaded.
do
  assert_eq(rt2_turbine.compute_coil_decision({ rpm = 100, target_rpm = 900, currently_engaged = false }).engaged, false,
    'a turbine ramping up must not be braked by its own coil')
  assert_eq(rt2_turbine.compute_coil_decision({ rpm = 850, target_rpm = 900, currently_engaged = false }).engaged, false,
    'still below the engage threshold on the way up -- stays uncoupled')
end

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

-- ── compute_active_decision ──────────────────────────────────────────────

do
  assert_true(rt2_turbine.compute_active_decision(false), 'a turbine reading OFF must be turned on')
  assert_true(rt2_turbine.compute_active_decision(nil), 'an unknown active reading must fail toward turning it on')
  assert_true(not rt2_turbine.compute_active_decision(true), 'a turbine already ON must not be re-activated every tick')
end

print('rt2_turbine_test.lua: ok')
