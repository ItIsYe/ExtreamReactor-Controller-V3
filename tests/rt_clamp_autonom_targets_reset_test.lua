package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (external code analysis, 2026-09-18): main.lua's real
-- (production) clamp_autonom_targets() closure -- called every AUTONOM
-- tick via state_handlers.lua's autonom_on_tick() -- only clamped NEGATIVE
-- power/steam/rpm values to 0. It never reset a STALE POSITIVE value left
-- over from the last MASTER-issued setpoint before the connection dropped,
-- so a node that fell back to AUTONOM after losing MASTER kept driving its
-- old power/steam targets indefinitely instead of actually going autonomous.
-- This diverged from state_handlers.lua's own exported (but otherwise
-- unused) M.clamp_autonom_targets(), which always force-zeroes power/steam.
--
-- Fix: main.lua's closure now unconditionally resets power/steam to 0 and
-- derives rpm from turbine_control.get_target_rpm(ctx) (capacity-learning
-- aware) instead of falling back to a fixed CONFIG.TARGET_RPM.
--
-- main.lua is a boot script (runs parallel.waitForAny() unconditionally at
-- the bottom), so it cannot be require()'d in a test process -- following
-- the same pattern as rt_main_state_context_guard_test.lua, this asserts
-- against the closure's exact source text.

local handle = assert(io.open('xreactor/nodes/rt/main.lua', 'r'))
local content = handle:read('*a')
handle:close()

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local clamp_start = content:find('clamp_autonom_targets%s*=%s*function%(%)')
assert_true(clamp_start, 'clamp_autonom_targets closure not found in main.lua')
local clamp_end = content:find('end,', clamp_start, true)
local clamp_body = content:sub(clamp_start, clamp_end)

assert_true(clamp_body:find('t%.power%s*=%s*0'),
  'clamp_autonom_targets must unconditionally reset power to 0 on AUTONOM entry, not just clamp negatives')
assert_true(clamp_body:find('t%.steam%s*=%s*0'),
  'clamp_autonom_targets must unconditionally reset steam to 0 on AUTONOM entry, not just clamp negatives')
assert_true(clamp_body:find('turbine_control%.get_target_rpm%(ctx%)'),
  'clamp_autonom_targets must derive rpm via turbine_control.get_target_rpm(ctx) (capacity-learning aware), not a fixed CONFIG.TARGET_RPM fallback')
assert_true(not clamp_body:find('math%.max%(0,%s*t%.rpm'),
  'clamp_autonom_targets must no longer leave a stale positive rpm target in place via math.max(0, t.rpm, ...)')

print('rt_clamp_autonom_targets_reset_test.lua: ok')
