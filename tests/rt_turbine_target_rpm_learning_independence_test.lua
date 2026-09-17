package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (user report 2026-09-17: "das einlernen von der
-- kapazitaet muss komplet unabhaengig sein sei es reaktor ein fuel rod
-- reglung als aucht turbinen flow reglung und induktion coil ein aus").
--
-- turbine_control.get_target_rpm() fed directly into flow regulation
-- (update_turbine_flow_state) AND the coil engage/disengage threshold
-- (update_inductor_for_rpm's scale=target_rpm/base_target) AND, via
-- get_turbine_target_rpm(), the per-turbine target during normal operation.
-- Before this fix, it read ctx.targets.rpm (the last MASTER-issued
-- setpoint) whenever current_state()==MASTER and that value was > 0 --
-- even while capacity_learning was not yet ready. A stale reduced
-- setpoint (e.g. 450 RPM from a prior partial-load SET_SETPOINTS that
-- simply stuck around after the node was parked/shut down) would then
-- permanently prevent capacity_learning.lua from ever reaching its
-- required 900+-15 RPM band -- coupling the learning process to whatever
-- the master last asked for, instead of it being fully independent.

local constants = require('shared.constants')
local turbine_control = require('nodes.rt.turbine_control')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ' expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local STATE = { INIT = 'INIT', MASTER = 'MASTER', AUTONOM = 'AUTONOM', SAFE = 'SAFE' }

local function make_ctx(opts)
  return {
    constants = constants,
    STATE = STATE,
    CONFIG = { TARGET_RPM = 900 },
    targets = opts.targets,
    capacity_learning = opts.capacity_learning,
    current_state = function() return opts.current_state end,
  }
end

-- 1) Learning not ready, MASTER connected, MASTER previously issued a
--    reduced (stale) setpoint -- must still target the full base RPM,
--    never the stale MASTER value. This is the exact bug scenario.
local ctx_stale_setpoint = make_ctx({
  current_state = STATE.MASTER, targets = { rpm = 450 },
  capacity_learning = { ready = false },
})
assert_eq(turbine_control.get_target_rpm(ctx_stale_setpoint), 900,
  'must ignore a stale/reduced MASTER rpm setpoint while capacity learning is not ready')

-- 2) Learning not ready, no capacity_learning state at all yet (nil) --
--    must also target the full base RPM.
local ctx_never_learned = make_ctx({
  current_state = STATE.MASTER, targets = { rpm = 450 },
  capacity_learning = nil,
})
assert_eq(turbine_control.get_target_rpm(ctx_never_learned), 900,
  'must target the full base RPM when capacity learning has never run')

-- 3) Learning ready, MASTER connected with a real setpoint -- normal
--    operation resumes: MASTER's rpm target is honoured again.
local ctx_ready_master = make_ctx({
  current_state = STATE.MASTER, targets = { rpm = 450 },
  capacity_learning = { ready = true },
})
assert_eq(turbine_control.get_target_rpm(ctx_ready_master), 450,
  'must honour the MASTER rpm setpoint once capacity learning is ready')

-- 4) Learning ready, AUTONOM (no master) -- falls back to the base RPM,
--    same as before this fix.
local ctx_ready_autonom = make_ctx({
  current_state = STATE.AUTONOM, targets = { rpm = 450 },
  capacity_learning = { ready = true },
})
assert_eq(turbine_control.get_target_rpm(ctx_ready_autonom), 900,
  'must fall back to the base RPM under AUTONOM regardless of learning state')

print('rt_turbine_target_rpm_learning_independence_test.lua: ok')
