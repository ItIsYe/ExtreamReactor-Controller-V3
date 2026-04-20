package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local config = dofile('xreactor/nodes/energy/config.lua')
if type(config.matrix_component_poll_interval) ~= 'number' then
  error('energy config must expose matrix_component_poll_interval')
end
if config.matrix_component_poll_interval <= 0 then
  error('matrix_component_poll_interval must be > 0')
end

print('energy_matrix_component_poll_interval_config_test.lua: ok')
