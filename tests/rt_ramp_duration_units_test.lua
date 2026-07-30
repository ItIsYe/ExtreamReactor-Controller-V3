package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer RT-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 12 "KRITISCH OFFEN"). module_lifecycle.lua's
-- process_startup() berechnet "progress = (now - module.start_time) /
-- duration", wobei "now"/"start_time" beide os.epoch("utc") in
-- MILLISEKUNDEN sind. Der echte Produktions-Stub in nodes/rt/main.lua gab
-- bisher "30" zurueck, benannt "ramp_duration" -- ohne Einheit -- und wurde
-- direkt als Divisor verwendet: die Rampe erreichte dadurch bereits nach
-- ~30 MILLISEKUNDEN 100% Fortschritt statt der beabsichtigten 30 SEKUNDEN.
-- Dieser Test treibt die echte process_startup()-Funktion mit einer Fake-
-- Clock ueber die tatsaechlichen Produktionswerte (30000ms, wie main.lua's
-- korrigierter "ramp_duration_ms"-Stub sie jetzt liefert).

local lifecycle = require('nodes.rt.module_lifecycle')

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

-- Real production value, mirrored from nodes/rt/main.lua's
-- ramp_duration_ms stub (STARTUP_RAMP_DURATION_S * 1000).
local PRODUCTION_RAMP_DURATION_MS = 30000

local clock = 1000000
local applied_levels = {}

local function make_ctx(module)
  local active = module.id
  return {
    modules = { [module.id] = module },
    config = { safety = { max_temperature = 2000, temperature_hysteresis = 5, temperature_trip_samples = 1 } },
    RPM_TOL = 20,
    comms = { network = { id = 'RT-1' } },
    set_active_startup = function(value) active = value end,
    get_active_startup = function() return active end,
    ramp_duration_ms = function() return PRODUCTION_RAMP_DURATION_MS end,
    setReactorActive = function() return true end,
    ensure_reactor_ctrl = function() return { last_applied = nil } end,
    applyReactorRods = function(level) applied_levels[#applied_levels + 1] = level end,
    -- update_module_limits()'s coolant check is called unconditionally
    -- regardless of the module's "isActivelyCooled" capability (a separate,
    -- pre-existing `skip_coolant and nil or ctx.evaluate_reactor_coolant(...)`
    -- classic Lua ternary bug -- the "or" branch always runs when its left
    -- side is nil, out of scope for this fix), so a real stub is required.
    evaluate_reactor_coolant = function() return nil end,
    add_alarm = function() end,
    log = function() end,
    warn_once = function() end,
    warn_unsupported = function() end,
  }
end

local module = {
  id = 'R1', type = 'reactor', name = 'reactor_0', state = 'STARTING', progress = 0,
  start_time = clock,
  caps = { setControlRodLevel = true },
  peripheral = {
    getCasingTemperature = function() return 900 end,
  },
}

local ctx = make_ctx(module)

os.epoch = function() return clock end

-- 1) After 100ms, the ramp must NOT be complete -- this is the exact
--    regression: the old code (dividing ms by a bare "30") would already
--    show progress==1/STABLE here.
clock = 1000000 + 100
lifecycle.process_startup(ctx)
assert_true(module.progress < 1, 'ramp must not be complete after only 100ms of a 30s ramp: progress=' .. tostring(module.progress))
assert_eq(module.state, 'STARTING', 'module must still be STARTING after 100ms')
local progress_at_100ms = module.progress

-- 2) Monotonic progression: further along the ramp, progress must have
--    increased (never reset or decreased).
clock = 1000000 + 15000
lifecycle.process_startup(ctx)
assert_true(module.progress > progress_at_100ms,
  'progress must increase monotonically: at100ms=' .. tostring(progress_at_100ms) .. ' at15s=' .. tostring(module.progress))
assert_true(module.progress < 1, 'ramp must still not be complete at the halfway point (15s of 30s)')
assert_eq(module.state, 'STARTING', 'module must still be STARTING at the halfway point')

-- 3) At/after the configured duration, the ramp completes and the module
--    reaches STABLE (desired duration per profile: the production stub is
--    profile-invariant today, but this proves the wall-clock deadline
--    itself is honored in real milliseconds).
clock = 1000000 + PRODUCTION_RAMP_DURATION_MS
lifecycle.process_startup(ctx)
assert_eq(module.state, 'STABLE', 'reactor should reach STABLE once the real 30s ramp duration has elapsed')

-- 4) Progress must clamp at 1, never exceed it, even long past the
--    deadline -- uses a second module whose temperature gate is
--    deliberately never satisfied, so it stays STARTING (never reaches
--    mark_stable()'s active-startup clear) and process_startup() keeps
--    recomputing progress from elapsed time on every call.
local stuck_module = {
  id = 'R2', type = 'reactor', name = 'reactor_1', state = 'STARTING', progress = 0,
  start_time = 1000000,
  caps = { setControlRodLevel = true },
  peripheral = {
    getCasingTemperature = function() return 0 end, -- never satisfies "temp > 0"
  },
}
local stuck_ctx = make_ctx(stuck_module)
clock = 1000000 + PRODUCTION_RAMP_DURATION_MS + 5000
lifecycle.process_startup(stuck_ctx)
assert_eq(stuck_module.progress, 1, 'progress must clamp at 1 well past the deadline, never exceed it')
assert_eq(stuck_module.state, 'STARTING', 'module stays STARTING while the temperature gate is unmet, independent of ramp progress')

print('rt_ramp_duration_units_test.lua: ok')
