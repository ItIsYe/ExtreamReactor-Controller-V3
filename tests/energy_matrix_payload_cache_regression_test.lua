local function read(path)
  local fh = assert(io.open(path, 'r'))
  local body = fh:read('*a')
  fh:close()
  return body
end

local source = read('xreactor/nodes/energy/main.lua')
local runtime_source = read('xreactor/nodes/energy/matrix_snapshot_runtime.lua')

if not source:find('matrix_metric_poll_interval', 1, true) then
  error('energy main config must include matrix_metric_poll_interval')
end
if not source:find('matrix_metric_call_budget', 1, true) then
  error('energy main config must include matrix_metric_call_budget')
end
if not source:find('matrix_metric_time_budget_ms', 1, true) then
  error('energy main config must include matrix_metric_time_budget_ms')
end
if not source:find('matrix_metric_slow_call_ms', 1, true) then
  error('energy main config must include matrix_metric_slow_call_ms')
end
if not source:find('matrix_metric_slow_poll_multiplier', 1, true) then
  error('energy main config must include matrix_metric_slow_poll_multiplier')
end
if not source:find('matrix_metric_per_matrix_budget', 1, true) then
  error('energy main config must include matrix_metric_per_matrix_budget')
end
if not runtime_source:find('dynamic_cache', 1, true) then
  error('expected matrix runtime dynamic cache to avoid duplicate matrix reads per tick')
end
if not runtime_source:find('static_cache', 1, true) then
  error('expected matrix runtime static cache for low-cadence component reads')
end
if not source:find('matrix_adapter.group_ports', 1, true) then
  error('expected logical matrix grouping so multiple ports do not duplicate matrix-wide reads')
end
if not runtime_source:find('Matrix metric polling throttled:', 1, true) then
  error('expected matrix metric throttling diagnostics for expensive matrix calls')
end
if not source:find('per_matrix_budget=', 1, true) then
  error('expected matrix metric throttling diagnostics to include per-matrix budget visibility')
end
if not source:find('time_budget_ms=', 1, true) then
  error('expected matrix metric throttling diagnostics to include time budget visibility')
end
if not runtime_source:find('job.cache[job.metric .. "_last_ms"]', 1, true) then
  error('expected matrix metric cache to track per-matrix/per-metric call duration for adaptive cadence')
end
if not source:find('Status payload slow matrix calls:', 1, true) then
  error('expected slow payload diagnostics to include concrete matrix metric calls')
end

print('energy_matrix_payload_cache_regression_test.lua: ok')
