local config = dofile('xreactor/nodes/energy/config.lua')

if type(config.matrix_metric_poll_interval) ~= 'number' then
  error('energy config must expose matrix_metric_poll_interval')
end
if config.matrix_metric_poll_interval <= 0 then
  error('matrix_metric_poll_interval must be > 0')
end

print('energy_matrix_metric_poll_interval_config_test.lua: ok')
