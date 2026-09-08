package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
_G.os.epoch = _G.os.epoch or function() return 0 end
local constants = require('shared.constants')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end
end

-- Regression test for a real-world bug found via field logs (2026-09-02):
-- "SET_SETPOINTS pct=100.0% state=active power=0" logged forever, even
-- long after capacity learning had already measured a real max_output.
--
-- nodes/rt/main.lua's build_command_ctx() is called exactly ONCE at init()
-- (command_handler_lib.new(build_command_ctx())) -- its ctx.capacity_learning
-- field is therefore a snapshot frozen at that moment (before any real
-- measurement exists), while ctx.get_capacity_learning() is a closure that
-- re-reads the live, continuously-updated capacity state on every call.
-- command_handler.lua's set_setpoints() used to read ctx.capacity_learning
-- directly (the frozen snapshot) instead of the dynamic getter, so
-- targets.power stayed 0 forever even after capacity_ready correctly
-- became true (which DOES use the getter via capacity_learning_locked()).
-- targets.power_percent -- the actual control value turbine_control.lua
-- reads -- was unaffected, but the "Soll"-power shown in the UI was not.
--
-- This test models the real production shape: only get_capacity_learning
-- is present on ctx (no static capacity_learning field), exactly like
-- nodes/rt/main.lua's build_command_ctx() output.

local CAP = { ready = true, max_output = 2000, reason = 'MEASURED', at_target = 50 }

local function mk_ctx()
  local targets = {}
  local ctx = {
    protocol = { is_for_node = function() return true end, is_proto_compatible = function() return true end },
    STATE = { MASTER = 'MASTER', SAFE = 'SAFE' }, targets = targets,
    get_current_state = function() return 'MASTER' end,
    get_states = function() return constants.node_states end,
    node_state_machine = { state = function() return constants.node_states.RUNNING end, transition = function() end },
    get_capacity_learning = function() return CAP end,
    request_startup_if_needed = function() end, apply_mode = function() end,
    start_module = function() return nil end, add_alarm = function() end,
    get_network_id = function() return 'RT-1' end, note_master_seen = function() end,
    set_last_command = function() end, set_last_command_ts = function() end
  }
  return ctx, targets
end

local handler = require('nodes.rt.command_handler')
local ctx, targets = mk_ctx()
local r = handler.new(ctx)({ proto_ver = constants.proto_ver, payload = { command = {
  target = constants.command_targets.SET_SETPOINTS,
  value = { power_target_percent = 100, assignment_state = 'active' }
} } })

assert_eq(r.ok, true, 'SET_SETPOINTS must succeed')
assert_eq(targets.power_percent, 100, 'power_percent must reflect the master setpoint')
assert_eq(targets.power, 2000,
  'targets.power must be derived from the LIVE capacity (via get_capacity_learning()), not a stale init-time snapshot')

print("rt_command_setpoints_power_target_test.lua: ok")
