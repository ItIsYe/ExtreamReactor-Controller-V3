package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local constants = require('shared.constants')
local handler = require('nodes.rt.command_handler')

local f=assert(io.open('xreactor/master/runtime_ops_rt.lua','r')); local content=f:read('*a'); f:close()
for _,stage in ipairs({'RAMPDOWN','REQUEST_STATE','REQUESTED','WAITING_STATE','COMPLETED','CANCELLED_DEMAND_RECOVERED','FAILED'}) do
  assert(content:find(stage,1,true),'missing shutdown workflow stage '..stage)
end
for _,reason in ipairs({'SUCCESS_COMPLETED','CANCELLED_DEMAND_RECOVERED','FAILED_TIMEOUT','FAILED_REJECTED','FAILED_INVALID_STATE','FAILED_ACK_MISSING'}) do
  assert(content:find(reason,1,true),'missing shutdown workflow reason '..reason)
end

local function new_handler(opts)
  opts=opts or {}
  local transitioned_to
  local current_state=opts.current_state or constants.node_states.RUNNING
  local runtime_mode=opts.runtime_mode or 'MASTER'
  local learning={ ready=true, max_output=100000, reason='TEST_LOCKED', at_target=5 }
  local command_handler=handler.new({
    protocol={ is_for_node=function() return true end, is_proto_compatible=function() return true end },
    STATE={ MASTER='MASTER', SAFE='SAFE' }, targets={}, capacity_learning=learning,
    get_capacity_learning=function() return learning end,
    get_current_state=function() return runtime_mode end,
    get_states=function() return constants.node_states end,
    node_state_machine={
      state=function() return current_state end,
      transition=function(_,next_state) transitioned_to=next_state end,
    },
    request_startup_if_needed=function() end, apply_mode=function() end,
    start_module=function() return nil end, add_alarm=function() end,
    get_network_id=function() return 'RT-1' end, note_master_seen=function() end,
    set_last_command=function() end, set_last_command_ts=function() end,
    log=function() end,
  })
  return command_handler,function() return transitioned_to end
end
local function request(value)
  return { proto_ver=constants.proto_ver, payload={ command={ target=constants.command_targets.SET_SETPOINTS, value=value } } }
end

do
  local ch,get_transition=new_handler({current_state=constants.node_states.RUNNING})
  local result=ch(request({desired_node_state=constants.node_states.OFF,shutdown_stage='REQUEST_OFF'}))
  assert(result and result.ok==true and result.transition=='REQUESTED','RUNNING->OFF must acknowledge REQUESTED')
  assert(get_transition()==constants.node_states.OFF,'REQUESTED must initiate OFF state transition')
end

do
  local ch,get_transition=new_handler({current_state=constants.node_states.OFF})
  local result=ch(request({desired_node_state=constants.node_states.OFF,shutdown_stage='REQUEST_OFF'}))
  assert(result and result.ok==true and result.transition=='ALREADY_IN_STATE','already OFF must be explicit')
  assert(get_transition()==nil,'ALREADY_IN_STATE must not transition again')
end

do
  local ch=new_handler({current_state=constants.node_states.RUNNING})
  local result=ch(request({desired_node_state='INVALID',shutdown_stage='REQUEST_OFF'}))
  assert(result and result.ok==false and result.reason_code=='INVALID_STATE','invalid desired state must fail explicitly')
end

do
  local ch=new_handler({runtime_mode='SAFE',current_state=constants.node_states.RUNNING})
  local result=ch(request({desired_node_state=constants.node_states.OFF,shutdown_stage='REQUEST_OFF'}))
  assert(result and result.ok==false and result.reason_code=='SAFE_MODE','SAFE mode must reject ordinary shutdown setpoint command')
end
print('master_rt_shutdown_workflow_semantics_guard_test.lua: ok')
