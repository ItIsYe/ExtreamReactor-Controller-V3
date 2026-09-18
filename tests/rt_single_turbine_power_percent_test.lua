package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (external code analysis, 2026-09-18): get_turbine_target_rpm()
-- returned the full base RPM (900) unconditionally whenever exactly one
-- turbine was configured (n <= 1), before ever looking at
-- ctx.targets.power_percent. A MASTER-issued 20%, 50%, or 80% power
-- request therefore all produced the SAME 900 RPM target for a single-
-- turbine RT node -- a real logic break between MASTER and RT.
--
-- Fix: the n<=1 short-circuit now only fires for n==0 (defends against a
-- modulo-by-zero in the slot algorithm below, which cannot occur in
-- practice since this is only ever called per configured turbine). The
-- existing multi-turbine VOLLAST/PUFFER/AUS algorithm already generalizes
-- correctly to n=1 on its own: with exactly one turbine there is never
-- room for a "full-load" slot unless power_percent is exactly 100, so the
-- single turbine always lands in the PUFFER branch with
-- partial_rpm = base * power_percent / 100.

local constants = require('shared.constants')
local turbine_control = require('nodes.rt.turbine_control')

local function assert_eq(a, b, m) if a ~= b then error((m or 'assert_eq') .. ': expected=' .. tostring(b) .. ' actual=' .. tostring(a)) end end

local function make_ctx(power_pct)
  return {
    constants = constants,
    STATE = { MASTER = 'MASTER' },
    CONFIG = { TARGET_RPM = 900 },
    config = { turbines = { 'T1' } },
    targets = { power_percent = power_pct, rpm = 0 },
    capacity_learning = { ready = true }, -- must be ready: get_turbine_target_rpm()
                                            -- only applies the power_percent split
                                            -- once learning is done (see file header).
    current_state = function() return 'MASTER' end,
    autonom_state = {},
    safety = require('core.safety'),
  }
end

-- 20%, 50%, 80% power requests must produce three DIFFERENT, correctly
-- scaled RPM targets for the single configured turbine -- not the same
-- 900 RPM every time.
local rpm_20 = turbine_control.get_turbine_target_rpm(make_ctx(20), 1)
local rpm_50 = turbine_control.get_turbine_target_rpm(make_ctx(50), 1)
local rpm_80 = turbine_control.get_turbine_target_rpm(make_ctx(80), 1)

assert_eq(rpm_20, 180, '20% of a single turbine must target 180 RPM (900 * 0.20)')
assert_eq(rpm_50, 450, '50% of a single turbine must target 450 RPM (900 * 0.50)')
assert_eq(rpm_80, 720, '80% of a single turbine must target 720 RPM (900 * 0.80)')
assert_eq(rpm_20 ~= rpm_50 and rpm_50 ~= rpm_80, true,
  'must never fall back to the same 900 RPM for every power_percent value')

-- 100% must still give the full base RPM.
local rpm_100 = turbine_control.get_turbine_target_rpm(make_ctx(100), 1)
assert_eq(rpm_100, 900, '100% power must target the full base RPM')

print('rt_single_turbine_power_percent_test.lua: ok')
