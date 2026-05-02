local handle, err = io.open('xreactor/master/main.lua', 'r')
if not handle then
  error('failed to open xreactor/master/main.lua: ' .. tostring(err))
end
local content = handle:read('*a')
handle:close()

local required_tokens = {
  'workflow.stage = "REQUESTED"',
  'workflow.stage = "WAITING_STATE"',
  'workflow.stage = "COMPLETED"',
  'workflow.final_reason = "SUCCESS_COMPLETED"',
  'workflow.final_reason = "CANCELLED_DEMAND_RECOVERED"',
  'workflow_fail("FAILED_TIMEOUT"',
  'workflow_fail("FAILED_REJECTED"',
  'workflow_fail("FAILED_INVALID_STATE"',
  'workflow_fail("FAILED_ACK_MISSING"',
  'if transition == "REQUESTED" or transition == "ALREADY_IN_STATE" then',
  'workflow.final_reason = "FAILED_UNKNOWN"'
}

for _, token in ipairs(required_tokens) do
  if not content:find(token, 1, true) then
    error('missing shutdown semantic guard token in master main: ' .. token)
  end
end

local completed_idx = assert(content:find('workflow.stage = "COMPLETED"', 1, true), 'missing completed stage assignment')
local state_check_idx = assert(content:find('if node.state == %(workflow.target_state or target_shutdown_state%) then'))
if completed_idx < state_check_idx then
  error('COMPLETED assignment must remain guarded by actual node target state check')
end

print('master_rt_shutdown_workflow_semantic_guards_test.lua: ok')
