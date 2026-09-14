package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (production log 2026-09-14, see uploaded disk6.zip):
-- nodes/rt/main.lua's build_command_ctx() runs (inside init()) BEFORE
-- configure_state_machine() ever assigns the node_state_machine upvalue.
-- A ctx field `node_state_machine = node_state_machine` set at that point
-- snapshots a permanent nil into the ctx table -- it is NOT a live
-- reference to the upvalue, so the machine constructed later is never
-- seen. Only a closure (`get_node_state_machine`) does. This crashed
-- transition_mode() (the MODE command) on every RT node in production:
-- "Handler error: .../command_ha:166: attempt to index field
-- 'node_state_machine' (a nil value)".
--
-- command_handler.lua now supports BOTH a direct `node_state_machine`
-- field (existing test mocks, e.g. rt_command_shutdown_transition_test.lua)
-- and a `get_node_state_machine()` getter, preferring the getter when
-- present -- exactly modelling main.lua's real ctx shape.

local constants = require('shared.constants')
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end
end
local function assert_true(v, m) if not v then error(m or 'true') end end

local handler = require('nodes.rt.command_handler')

-- 1) Simulate main.lua's real bug scenario: node_state_machine is nil when
--    the ctx closure is FIRST evaluated (build_command_ctx() ran before
--    configure_state_machine()), but a later call to the getter sees the
--    real machine that gets assigned afterwards -- exactly what a Lua
--    closure over an upvalue does, unlike a value snapshotted into a
--    table field at construction time.
local real_machine = nil -- not yet assigned, like the real upvalue at build_command_ctx() time
local transitioned_to = nil
local function mk_ctx(cur_state)
  return {
    protocol = { is_for_node = function() return true end, is_proto_compatible = function() return true end },
    STATE = { MASTER = 'MASTER', SAFE = 'SAFE' }, targets = {},
    get_current_state = function() return cur_state end,
    get_states = function() return constants.node_states end,
    -- No direct `node_state_machine` field at all -- only the getter, like
    -- main.lua's build_command_ctx() after this fix.
    get_node_state_machine = function() return real_machine end,
    get_capacity_learning = function() return { ready = true, max_output = 3000, reason = 'MEASURED', at_target = 5 } end,
    request_startup_if_needed = function() end, apply_mode = function() end,
    start_module = function() return nil end, add_alarm = function() end,
    get_network_id = function() return 'RT-1' end, note_master_seen = function() end,
    set_last_command = function() end, set_last_command_ts = function() end,
  }
end

local ctx = mk_ctx('MASTER')
local handle = handler.new(ctx)

-- MODE command while the machine is still nil (matches the exact crash
-- window in production, right at startup) must NOT crash -- it should be
-- a documented, harmless no-op (nothing to transition yet).
local ok = pcall(handle, { proto_ver = constants.proto_ver, payload = { command = {
  target = constants.command_targets.MODE, value = constants.node_states.RUNNING,
} } })
assert_true(ok, 'MODE command must not crash while node_state_machine is not yet assigned')

-- Now assign the "real" machine, exactly like configure_state_machine()
-- does later in init() -- the getter must see it immediately, proving
-- this is a live reference, not a stale snapshot.
real_machine = {
  state = function() return constants.node_states.RUNNING end,
  transition = function(_, s) transitioned_to = s end,
}
local ok2 = pcall(handle, { proto_ver = constants.proto_ver, payload = { command = {
  target = constants.command_targets.MODE, value = constants.node_states.OFF,
} } })
assert_true(ok2, 'MODE command must not crash once node_state_machine is assigned')
assert_eq(transitioned_to, constants.node_states.OFF, 'MODE command must transition the now-live machine')

-- 2) SET_SETPOINTS' desired_node_state path (command_handler.lua line
--    ~105) must use the same live getter too.
transitioned_to = nil
local ok3 = pcall(handle, { proto_ver = constants.proto_ver, payload = { command = {
  target = constants.command_targets.SET_SETPOINTS,
  value = { power_target_percent = 0, assignment_state = 'shutdown',
    desired_node_state = constants.node_states.OFF, shutdown_stage = 'REQUEST_OFF' },
} } })
assert_true(ok3, 'SET_SETPOINTS desired_node_state path must not crash')
assert_eq(transitioned_to, constants.node_states.OFF, 'SET_SETPOINTS must transition via the live getter too')

print('rt_command_handler_node_state_machine_getter_test.lua: ok')
