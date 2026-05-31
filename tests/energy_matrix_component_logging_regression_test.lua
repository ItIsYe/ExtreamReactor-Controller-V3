local function read(path)
  local handle, err = io.open(path, 'r')
  if not handle then
    error('unable to read ' .. tostring(path) .. ': ' .. tostring(err))
  end
  local content = handle:read('*a')
  handle:close()
  return content
end

local source = read('xreactor/nodes/energy/main.lua')

if source:find('cells == nil or providers == nil or ports == nil', 1, true) then
  error('matrix component unavailability check must not require optional ports')
end

if not source:find('matrix_component_diag', 1, true) then
  error('expected matrix component diagnostics cache for log dedupe')
end

if not source:find('if previous == stamp then', 1, true) then
  error('expected component warning dedupe guard to avoid repeated identical logs')
end

if not source:find('reason=api_variant', 1, true) and not source:find('"api_variant"', 1, true) then
  error('expected explicit api_variant reason classification')
end

if not source:find('"temporary_not_ready"', 1, true) then
  error('expected explicit temporary_not_ready classification for nil component payloads')
end

print('energy_matrix_component_logging_regression_test.lua: ok')
