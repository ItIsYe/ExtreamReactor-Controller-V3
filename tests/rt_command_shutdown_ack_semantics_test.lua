package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local constants = require('shared.constants')
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end
end
local function assert_true(v, m) if not v then error(m or 'true') end end
local CAP = { ready=true, max_output=3000, reason='MEASURED', at_target=5 }
local function mk_ctx(cur_state, machine_state)
  local tr
  local ctx = {
    protocol={is_for_node=function() return true end,is_proto_compatible=function() return true end},
    STATE={MASTER='MASTER',SAFE='SAFE'}, targets={},
    get_current_state=function() return cur_state end,
    get_states=function() return constants.node_states end,
    node_state_machine={state=function() return machine_state end,transition=function(_,s) tr=s end},
    get_capacity_learning=function() return CAP end,
    request_startup_if_needed=function() end, apply_mode=function() end,
    start_module=function() return nil end, add_alarm=function() end,
    get_network_id=function() return 'RT-1' end, note_master_seen=function() end,
    set_last_command=function() end, set_last_command_ts=function() end
  }
  return ctx, function() return tr end
end

local handler = require('nodes.rt.command_handler')
local ctx1, get_t1 = mk_ctx('MASTER', constants.node_states.RUNNING)
local r1 = handler.new(ctx1)({ proto_ver=constants.proto_ver, payload={ command={
  target=constants.command_targets.SET_SETPOINTS,
  value={power_target_percent=0,assignment_state='shutdown',desired_node_state=constants.node_states.OFF,shutdown_stage='REQUEST_OFF'}
}}})
assert_true(r1 ~= nil, 'must return result')
assert_eq(r1.ok, true, 'shutdown must succeed for RUNNING node')
assert_eq(r1.transition, 'REQUESTED', 'shutdown request must return REQUESTED when transition is initiated')
assert_eq(get_t1(), constants.node_states.OFF, 'must transition towards OFF')
local ctx2, _ = mk_ctx('SAFE', constants.node_states.RUNNING)
local r2 = handler.new(ctx2)({ proto_ver=constants.proto_ver, payload={ command={
  target=constants.command_targets.SET_SETPOINTS,
  value={power_target_percent=0,assignment_state='shutdown',desired_node_state=constants.node_states.OFF,shutdown_stage='REQUEST_OFF'}
}}})
assert_eq(r2.ok, false, 'SAFE mode must reject')
assert_eq(r2.reason_code, 'SAFE_MODE', 'SAFE_MODE reason')
print("rt_command_shutdown_ack_semantics_test.lua: ok")
