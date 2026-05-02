local handle, err = io.open('xreactor/master/main.lua', 'r')
if not handle then
  error('failed to open xreactor/master/main.lua: ' .. tostring(err))
end
local content = handle:read('*a')
handle:close()

local required_stages = {
  'RAMPDOWN',
  'REQUEST_STATE',
  'REQUESTED',
  'WAITING_STATE',
  'COMPLETED',
  'CANCELLED_DEMAND_RECOVERED',
  'FAILED'
}

for _, stage in ipairs(required_stages) do
  if not content:find(stage, 1, true) then
    error('missing required shutdown workflow stage in master/main.lua: ' .. tostring(stage))
  end
end

local required_reasons = {
  'SUCCESS_COMPLETED',
  'CANCELLED_DEMAND_RECOVERED',
  'FAILED_TIMEOUT',
  'FAILED_REJECTED',
  'FAILED_INVALID_STATE',
  'FAILED_ACK_MISSING'
}

local required_outcomes = {
  'workflow.outcome = "SUCCESS"',
  'workflow.outcome = "CANCELLED"',
  'workflow.outcome = "FAILED"'
}

for _, reason in ipairs(required_reasons) do
  if not content:find(reason, 1, true) then
    error('missing required shutdown workflow final reason in master/main.lua: ' .. tostring(reason))
  end
end

for _, outcome_token in ipairs(required_outcomes) do
  if not content:find(outcome_token, 1, true) then
    error('missing required shutdown workflow outcome contract in master/main.lua: ' .. tostring(outcome_token))
  end
end

if content:find('workflow cleared node=%%s reason=DEMAND_RECOVERED', 1, true) then
  error('legacy demand-recovered cleanup log found; this can hide successful completion')
end

print('master_rt_shutdown_workflow_semantics_guard_test.lua: ok')


if not content:find('RT shutdown workflow cleanup node=%s final_reason=%s stage=%s', 1, true) then
  error('missing explicit cleanup log with preserved final_reason')
end

if not content:find('workflow.stage = "REQUESTED"', 1, true) or not content:find('workflow.stage = "COMPLETED"', 1, true) then
  error('REQUESTED and COMPLETED stages must stay explicitly distinct')
end

if not content:find('workflow.stage == "REQUEST_STATE" or workflow.stage == "REQUESTED"', 1, true) then
  error('request phase contract missing; REQUESTED must stay non-final')
end
if not content:find('workflow.stage == "WAITING_STATE"', 1, true) then
  error('waiting phase contract missing; completion must wait for real node state')
end
if not content:find('workflow_fail("FAILED_ACK_MISSING", "ACK_MISSING")', 1, true) then
  error('missing explicit FAILED_ACK_MISSING contract')
end


if not content:find('if node.state == %(workflow.target_state or target_shutdown_state%) then', 1, false) then
  error('completion must remain bound to actual node.state reaching target')
end
if not content:find('RT shutdown workflow request sent node=%s', 1, true) then
  error('missing request-sent diagnostic log contract')
end
if not content:find('RT shutdown workflow request accepted node=%s', 1, true) then
  error('missing request-accepted diagnostic log contract')
end
if not content:find('RT shutdown workflow finalised node=%s final_reason=%s', 1, true) then
  error('missing finalised success log contract')
end
if not content:find('RT shutdown workflow state_reached_at set node=%s state_reached_at=%s', 1, true) then
  error('missing explicit state_reached_at diagnostic log contract')
end
if not content:find('RT shutdown workflow terminal field gap node=%s stage=%s outcome=%s final_reason=%s completed_at=%s', 1, true) then
  error('missing terminal UI-field consistency warning guard log contract')
end
if not content:find('cleanup guard node=%s corrected_final_reason=%s', 1, true) then
  error('missing cleanup final-reason guard contract')
end
