package.path = package.path .. ";/workspace/ExtreamReactor-Controller-V3/?.lua"

local rails = dofile("/workspace/ExtreamReactor-Controller-V3/xreactor/core/control_rails.lua")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_eq failed") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then
    error(message or "assert_true failed")
  end
end

local function test_rate_limit_blocks_large_single_jump()
  local state = rails.new_state()
  local next_rods, diag = rails.ramp_target(90, 20, {
    max_apply_step_up = 5,
    max_apply_step_down = 5,
    min = 0,
    max = 98
  }, { state = state, now = 10 })

  assert_eq(next_rods, 85, "rod jump must be rate-limited to 5 per cycle")
  assert_eq(diag.reason, "RAMP_APPLIED", "large jumps must be logged as ramp-applied")
  assert_eq(diag.requested_delta, -70, "requested delta must be preserved for diagnostics")
  assert_eq(diag.applied_delta, -5, "applied delta must respect max step")
end

local function test_ramp_requires_multiple_cycles()
  local state = rails.new_state()
  local cfg = {
    max_apply_step_up = 5,
    max_apply_step_down = 5,
    apply_cooldown_s = 0,
    min = 0,
    max = 98
  }

  local rods = 90
  rods = rails.ramp_target(rods, 20, cfg, { state = state, now = 1 })
  rods = rails.ramp_target(rods, 20, cfg, { state = state, now = 2 })
  rods = rails.ramp_target(rods, 20, cfg, { state = state, now = 3 })

  assert_eq(rods, 75, "target approach must be gradual over multiple cycles")
end

local function test_coolant_soft_limiter_damps_power_up()
  local state = rails.new_state()
  local next_rods, diag = rails.ramp_target(60, 45, {
    max_apply_step_up = 5,
    max_apply_step_down = 5,
    coolant_ramp_soft_limit_ratio = 0.28,
    coolant_ramp_hard_limit_ratio = 0.22,
    max_step_down_when_coolant_soft = 2,
    max_step_down_when_coolant_hard = 0,
    min = 0,
    max = 98
  }, {
    state = state,
    now = 10,
    coolant_ratio = 0.25,
    safety_min_water = 0.2
  })

  assert_eq(next_rods, 58, "coolant soft limiter must reduce withdraw step")
  assert_true(diag.coolant_limited, "coolant-limited flag must be true")
  assert_eq(diag.coolant_reason, "SOFT", "soft coolant zone must be classified")
end

test_rate_limit_blocks_large_single_jump()
test_ramp_requires_multiple_cycles()
test_coolant_soft_limiter_damps_power_up()

print("reactor_rod_ramp_regression_test.lua: ok")
