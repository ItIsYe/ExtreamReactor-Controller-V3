local main_handle, main_err = io.open('xreactor/master/main.lua', 'r')
if not main_handle then
  error('failed to open xreactor/master/main.lua: ' .. tostring(main_err))
end
local main_content = main_handle:read('*a')
main_handle:close()

local ui_handle, ui_err = io.open('xreactor/master/ui_controller.lua', 'r')
if not ui_handle then
  error('failed to open xreactor/master/ui_controller.lua: ' .. tostring(ui_err))
end
local ui_content = ui_handle:read('*a')
ui_handle:close()

local ui_fields = {
  'shutdown_workflow_stage',
  'shutdown_workflow_error',
  'shutdown_workflow_reason',
  'shutdown_workflow_outcome',
  'shutdown_requested_at',
  'shutdown_accepted_at',
  'shutdown_state_reached_at',
  'shutdown_completed_at'
}

for _, field in ipairs(ui_fields) do
  if not ui_content:find(field, 1, true) then
    error('missing RT shutdown ui field projection: ' .. tostring(field))
  end
end

local workflow_contracts = {
  'workflow.stage = "COMPLETED"',
  'workflow.final_reason = "SUCCESS_COMPLETED"',
  'workflow.outcome = "SUCCESS"',
  'workflow.state_reached_at = now',
  'workflow.stage = "CANCELLED_DEMAND_RECOVERED"',
  'workflow.final_reason = "CANCELLED_DEMAND_RECOVERED"',
  'workflow.outcome = "CANCELLED"',
  'workflow_fail("FAILED_ACK_MISSING", "ACK_MISSING")'
}

for _, token in ipairs(workflow_contracts) do
  if not main_content:find(token, 1, true) then
    error('missing workflow/ui shutdown consistency token: ' .. tostring(token))
  end
end

print('master_ui_shutdown_field_consistency_guard_test.lua: ok')
