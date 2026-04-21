local function read(path)
  local fh = assert(io.open(path, 'r'))
  local body = fh:read('*a')
  fh:close()
  return body
end

local source = read('xreactor/nodes/energy/main.lua')
local runtime_source = read('xreactor/nodes/energy/matrix_snapshot_runtime.lua')

if not source:find('matrix_metric_time_budget_ms', 1, true) then
  error('expected matrix_metric_time_budget_ms config usage for matrix polling pacing')
end
if not runtime_source:find('poll_spent_ms', 1, true) then
  error('expected cumulative matrix polling spent time accounting')
end
if not runtime_source:find('poll_spent_ms >= metric_time_budget_ms', 1, true) then
  error('expected matrix polling loop to stop once cumulative time budget is exhausted')
end
if not runtime_source:find('heartbeat_pump(now_ms())', 1, true) then
  error('expected heartbeat pump invocation while matrix polling runs')
end
if not runtime_source:find('time_budget_ms=%d spent_ms=%d', 1, true) then
  error('expected matrix throttle log to include time budget and spent duration')
end

print('energy_matrix_polling_pacing_regression_test.lua: ok')
