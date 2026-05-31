package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local guard = require("nodes.rt.reactor_steam_guard")

local function assert_true(value, message)
  if not value then
    error(message or "assert_true failed")
  end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_eq failed") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
  end
end

local cfg = {
  enabled = true,
  high_ratio = 0.8,
  high_release_ratio = 0.7,
  critical_ratio = 0.9,
  critical_release_ratio = 0.85,
  force_close_step = 2,
  ema_alpha = 0.99 -- near-immediate response while still inside valid (0, 1) range
}

local state = {}

local target, diag = guard.apply(82, 78, 0.82, cfg, state)
assert_eq(target, 82, "high threshold must block extra opening")
assert_true(diag.blocked_opening, "high threshold must report blocked opening")
assert_true(diag.high_active, "high state must latch active at threshold")

target, diag = guard.apply(82, 81, 0.75, cfg, state)
assert_eq(target, 82, "hysteresis should keep high guard active above release")
assert_true(diag.high_active, "high guard should stay active until release threshold")

target, diag = guard.apply(82, 81, 0.65, cfg, state)
assert_eq(target, 81, "high guard should release below release threshold")
assert_true(not diag.high_active, "high guard should clear after release")

target, diag = guard.apply(82, 76, 0.95, cfg, state)
assert_eq(target, 84, "critical guard should force controlled close step")
assert_true(diag.forced_closing, "critical guard should report forced close action")
assert_true(diag.critical_active, "critical state should be active")

target, diag = guard.apply(82, 79, nil, cfg, state)
assert_eq(target, 84, "critical state should remain latched when no new sample is available")
assert_true(diag.unavailable, "missing sample should be reported")

print("rt_reactor_steam_guard_test.lua: ok")
