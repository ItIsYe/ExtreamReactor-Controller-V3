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

for _, reason in ipairs(required_reasons) do
  if not content:find(reason, 1, true) then
    error('missing required shutdown workflow final reason in master/main.lua: ' .. tostring(reason))
  end
end

if content:find('workflow cleared node=%%s reason=DEMAND_RECOVERED', 1, true) then
  error('legacy demand-recovered cleanup log found; this can hide successful completion')
end

print('master_rt_shutdown_workflow_semantics_guard_test.lua: ok')


if not content:find('RT shutdown workflow cleanup node=%s final_reason=%s', 1, true) then
  error('missing explicit cleanup log with preserved final_reason')
end

if not content:find('workflow.stage = "REQUESTED"', 1, true) or not content:find('workflow.stage = "COMPLETED"', 1, true) then
  error('REQUESTED and COMPLETED stages must stay explicitly distinct')
end
