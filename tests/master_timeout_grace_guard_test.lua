local f=assert(io.open('xreactor/master/runtime_ops_rt.lua','r'));local s=f:read('*a');f:close()
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
