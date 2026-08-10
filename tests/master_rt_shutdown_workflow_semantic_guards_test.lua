local f=assert(io.open('xreactor/master/runtime_ops_rt.lua','r'));local s=f:read('*a');f:close()
local required={'workflow.stage = "REQUESTED"','workflow.stage = "WAITING_STATE"','workflow.stage = "COMPLETED"',
'workflow.final_reason = "SUCCESS_COMPLETED"','workflow_fail("FAILED_TIMEOUT"','workflow_fail("FAILED_REJECTED"',
'workflow_fail("FAILED_INVALID_STATE"','workflow_fail("FAILED_ACK_MISSING"','workflow.final_reason = "FAILED_UNKNOWN"'}
for _,t in ipairs(required) do assert(s:find(t,1,true),'missing current shutdown semantic token '..t) end
local completed=assert(s:find('workflow.stage = "COMPLETED"',1,true)); local statecheck=assert(s:find('if node.state == (workflow.target_state or target_shutdown_state) then',1,true))
assert(completed>statecheck,'COMPLETED must remain behind actual target-state verification')
print('master_rt_shutdown_workflow_semantic_guards_test.lua: ok')
