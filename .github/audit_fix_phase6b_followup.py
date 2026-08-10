from pathlib import Path

ROOT = Path('.')

def write(path, content):
    (ROOT / path).write_text(content, encoding='utf-8')

# Current, intentionally conservative peer stability defaults.
write('tests/comms_stability_defaults_regression_test.lua', '''package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local comms=require('core.comms')
local master=dofile('xreactor/master/config.lua')
local energy=dofile('xreactor/nodes/energy/config.lua')
local mc=assert(master.comms,'master comms missing'); local ec=assert(energy.comms,'energy comms missing')
assert(mc.peer_down_grace_s==5.0 and mc.peer_down_min_observations==2
  and mc.peer_up_debounce_s==1.5 and mc.peer_up_min_observations==2,
  'master peer hysteresis defaults drifted')
assert(ec.peer_down_grace_s==10.0 and ec.peer_down_min_observations==3
  and ec.peer_up_debounce_s==3.0 and ec.peer_up_min_observations==3,
  'energy peer hysteresis defaults drifted')
assert(energy.matrix_metric_poll_interval==12.0,'energy matrix poll interval drifted')
local sanitized=comms.sanitize_config({peer_timeout_s=1,peer_down_grace_s=-5,peer_up_debounce_s=-1,peer_up_min_observations=0})
assert(sanitized.peer_down_grace_s>=0 and sanitized.peer_up_debounce_s>=0 and sanitized.peer_up_min_observations>=1,
  'comms sanitizer must keep stability bounds safe')
print('comms_stability_defaults_regression_test.lua: ok')
''')

# The RT command handler correctly refuses SET_SETPOINTS until capacity learning
# is locked. This fixture explicitly satisfies that independent safety gate so
# it can test shutdown state-transition semantics rather than being rejected
# earlier for CAPACITY_LEARNING.
write('tests/master_rt_shutdown_workflow_semantics_guard_test.lua', '''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
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
''')

# Current shutdown workflow uses explicit 15s deadlines in runtime_ops_rt.lua.
# Guard ordering: ACK missing only after request timeout; state timeout only after
# accepted ACK while WAITING_STATE.
write('tests/master_timeout_grace_guard_test.lua', '''local f=assert(io.open('xreactor/master/runtime_ops_rt.lua','r'));local s=f:read('*a');f:close()
for _,token in ipairs({'FAILED_ACK_MISSING','FAILED_TIMEOUT','WAITING_STATE','workflow.request_command_at','workflow.command_ack_at'}) do
  assert(s:find(token,1,true),'missing timeout workflow contract '..token)
end
local ack_deadline='if not workflow.request_ack_at and workflow.request_command_at and now - workflow.request_command_at > 15000 then'
local state_deadline='if workflow.command_ack_at and now - workflow.command_ack_at > 15000 then'
assert(s:find(ack_deadline,1,true),'ACK-missing timeout must remain explicit 15s from request command')
assert(s:find(state_deadline,1,true),'state-transition timeout must remain explicit 15s from accepted command ACK')
local waiting=assert(s:find('elseif workflow.stage == "WAITING_STATE" then',1,true))
local state_fail=assert(s:find('workflow_fail("FAILED_TIMEOUT"',waiting,true))
assert(state_fail>waiting,'state timeout must be scoped to WAITING_STATE')
print('master_timeout_grace_guard_test.lua: ok')
''')

print('phase6b final Lua contract fixtures aligned')
