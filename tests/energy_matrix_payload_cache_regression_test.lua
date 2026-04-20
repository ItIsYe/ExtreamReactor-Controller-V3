local function read(path)
  local fh = assert(io.open(path, 'r'))
  local body = fh:read('*a')
  fh:close()
  return body
end

local source = read('xreactor/nodes/energy/main.lua')

if not source:find('matrix_metric_poll_interval', 1, true) then
  error('energy main config must include matrix_metric_poll_interval')
end
if not source:find('matrix_metric_cache', 1, true) then
  error('expected matrix metric cache to avoid duplicate matrix reads per tick')
end
if not source:find('Status payload slow matrix calls:', 1, true) then
  error('expected slow payload diagnostics to include concrete matrix metric calls')
end

print('energy_matrix_payload_cache_regression_test.lua: ok')
