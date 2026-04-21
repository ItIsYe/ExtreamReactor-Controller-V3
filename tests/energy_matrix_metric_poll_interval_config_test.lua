local config = dofile('xreactor/nodes/energy/config.lua')

if type(config.matrix_metric_poll_interval) ~= 'number' then
  error('energy config must expose matrix_metric_poll_interval')
end
if config.matrix_metric_poll_interval <= 0 then
  error('matrix_metric_poll_interval must be > 0')
end
if type(config.matrix_metric_call_budget) ~= 'number' then
  error('energy config must expose matrix_metric_call_budget')
end
if config.matrix_metric_call_budget <= 0 then
  error('matrix_metric_call_budget must be > 0')
end
if type(config.matrix_metric_time_budget_ms) ~= 'number' then
  error('energy config must expose matrix_metric_time_budget_ms')
end
if config.matrix_metric_time_budget_ms < 100 then
  error('matrix_metric_time_budget_ms must be >= 100')
end
if type(config.matrix_metric_slow_call_ms) ~= 'number' then
  error('energy config must expose matrix_metric_slow_call_ms')
end
if config.matrix_metric_slow_call_ms < 50 then
  error('matrix_metric_slow_call_ms must be >= 50')
end
if type(config.matrix_metric_slow_poll_multiplier) ~= 'number' then
  error('energy config must expose matrix_metric_slow_poll_multiplier')
end
if config.matrix_metric_slow_poll_multiplier < 1 then
  error('matrix_metric_slow_poll_multiplier must be >= 1')
end
if type(config.matrix_metric_per_matrix_budget) ~= 'number' then
  error('energy config must expose matrix_metric_per_matrix_budget')
end
if config.matrix_metric_per_matrix_budget <= 0 then
  error('matrix_metric_per_matrix_budget must be > 0')
end

print('energy_matrix_metric_poll_interval_config_test.lua: ok')
