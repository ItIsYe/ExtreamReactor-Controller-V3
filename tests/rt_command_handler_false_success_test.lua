package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (external code analysis, 2026-09-18): command_handler.lua's
-- dispatcher treated ANY handler that returned nil as an implicit
-- {ok=true} success. But set_scalar_target() (POWER_TARGET/STEAM_TARGET/
-- TURBINE_RPM) and transition_mode() (MODE) both silently `return`ed nil on
-- a legitimate REJECTION (node not in MASTER mode, or -- for MODE -- an
-- unknown target state), and SET_REACTOR_FILL_TARGET's invalid-value guard
-- also `return`ed nil. In all of these cases MASTER received {ok=true} for
-- a command that was actually dropped on the floor.
--
-- Fix: these handlers now return an explicit {ok=false, error=...,
-- reason_code=...} result on rejection instead of nil.

local constants = require('shared.constants')
local handler = require('nodes.rt.command_handler')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end

local function mk_ctx(cur_state, machine)
  return {
    protocol = { is_for_node = function() return true end, is_proto_compatible = function() return true end },
    STATE = { MASTER = 'MASTER', AUTONOM = 'AUTONOM', SAFE = 'SAFE' },
    TARGET_RPM = 900,
    targets = {},
    get_current_state = function() return cur_state end,
    get_states = function() return constants.node_states end,
    get_node_state_machine = function() return machine end,
    get_capacity_learning = function() return { ready = false } end,
    request_startup_if_needed = function() end,
    apply_mode = function() end,
    start_module = function() return nil end,
    add_alarm = function() end,
    get_network_id = function() return 'RT-1' end,
    note_master_seen = function() end,
    set_last_command = function() end,
    set_last_command_ts = function() end,
    set_reactor_fill_target = function() return true end,
    log = function() end,
  }
end

local function send(ctx, target, value)
  local handle = handler.new(ctx)
  return handle({ proto_ver = constants.proto_ver, payload = { command = { target = target, value = value } } })
end

-- POWER_TARGET/STEAM_TARGET/TURBINE_RPM while NOT in MASTER must be a real
-- rejection, not an implicit {ok=true}.
for _, target in ipairs({ 'POWER_TARGET', 'STEAM_TARGET', 'TURBINE_RPM' }) do
  local ctx = mk_ctx('AUTONOM', nil)
  local result = send(ctx, target, 42)
  assert_true(result and result.ok == false, target .. ' in AUTONOM must be rejected, not {ok=true}')
  assert_eq(result.reason_code, 'INVALID_STATE', target .. ' rejection reason_code')
end

-- POWER_TARGET while in MASTER must still succeed and apply the value.
do
  local ctx = mk_ctx('MASTER', nil)
  local result = send(ctx, 'POWER_TARGET', 42)
  assert_true(result == nil or result.ok ~= false, 'POWER_TARGET in MASTER must not be rejected')
  assert_eq(ctx.targets.power, 42, 'POWER_TARGET in MASTER must apply the value')
end

-- MODE while NOT in MASTER must be rejected.
do
  local ctx = mk_ctx('AUTONOM', { state = function() return constants.node_states.RUNNING end, transition = function() end })
  local result = send(ctx, 'MODE', constants.node_states.OFF)
  assert_true(result and result.ok == false, 'MODE in AUTONOM must be rejected, not {ok=true}')
  assert_eq(result.reason_code, 'INVALID_STATE', 'MODE rejection reason_code')
end

-- MODE with an unknown target state must be rejected, not silently no-op'd
-- into a false success.
do
  local transitioned = false
  local ctx = mk_ctx('MASTER', { state = function() return constants.node_states.RUNNING end, transition = function() transitioned = true end })
  local result = send(ctx, 'MODE', 'NOT_A_REAL_STATE')
  assert_true(result and result.ok == false, 'MODE with an invalid value must be rejected')
  assert_eq(result.reason_code, 'INVALID_VALUE', 'MODE invalid value reason_code')
  assert_true(not transitioned, 'an invalid MODE value must never reach machine:transition()')
end

-- MODE with a valid target state in MASTER must still succeed.
do
  local transitioned_to = nil
  local ctx = mk_ctx('MASTER', { state = function() return constants.node_states.RUNNING end, transition = function(_, s) transitioned_to = s end })
  local result = send(ctx, 'MODE', constants.node_states.OFF)
  assert_true(result == nil or result.ok ~= false, 'valid MODE transition in MASTER must not be rejected')
  assert_eq(transitioned_to, constants.node_states.OFF, 'valid MODE transition must reach machine:transition()')
end

-- SET_REACTOR_FILL_TARGET with an out-of-range value must be rejected.
do
  local ctx = mk_ctx('MASTER', nil)
  local result = send(ctx, 'SET_REACTOR_FILL_TARGET', 1.5)
  assert_true(result and result.ok == false, 'SET_REACTOR_FILL_TARGET out of range must be rejected, not {ok=true}')
  assert_eq(result.reason_code, 'INVALID_VALUE', 'SET_REACTOR_FILL_TARGET rejection reason_code')
end

-- SET_REACTOR_FILL_TARGET with a valid value must still succeed.
do
  local ctx = mk_ctx('MASTER', nil)
  local result = send(ctx, 'SET_REACTOR_FILL_TARGET', 0.5)
  assert_true(result and result.ok == true, 'SET_REACTOR_FILL_TARGET with a valid value must succeed')
end

print('rt_command_handler_false_success_test.lua: ok')
