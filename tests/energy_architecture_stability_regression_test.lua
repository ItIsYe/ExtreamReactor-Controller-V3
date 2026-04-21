local function read(path)
  local fh = assert(io.open(path, 'r'))
  local body = fh:read('*a')
  fh:close()
  return body
end

local main_source = read('xreactor/nodes/energy/main.lua')
local runtime_source = read('xreactor/nodes/energy/matrix_snapshot_runtime.lua')
local matrix_source = read('xreactor/adapters/induction_matrix.lua')
local topology_source = read('xreactor/nodes/energy/matrix_topology_cache.lua')

if not main_source:find('topology_changed', 1, true) then
  error('expected topology_changed gate for discovery invalidation')
end
if not main_source:find('matrix_runtime and topology_changed then', 1, true) then
  error('expected matrix runtime invalidation only on topology change')
end
if not main_source:find('matrix_identity_cache', 1, true) then
  error('expected persistent matrix_identity_cache for grouping stability')
end
if not main_source:find('reconcile_matrix_groups', 1, true) then
  error('expected stable matrix group reconciliation to avoid rebuild churn')
end
if not main_source:find('should_discover = function', 1, true) then
  error('expected discovery gating callback to keep discovery off hot path')
end
if not main_source:find('name = "STORAGE_SAMPLE"', 1, true) then
  error('expected dedicated STORAGE_SAMPLE service for snapshot-first telemetry/ui')
end
if not main_source:find('effective_matrix_count', 1, true) or not main_source:find('effective_storage_count', 1, true) then
  error('expected effective binding counts based on live snapshots, not only discovery moment')
end
if not runtime_source:find('matrix_component_call_budget', 1, true) then
  error('expected matrix component polling call budget support')
end
if not runtime_source:find('last_good_', 1, true) then
  error('expected last-good matrix metric persistence in snapshot runtime')
end
if not runtime_source:find('missing =', 1, true) or not runtime_source:find('stale =', 1, true) then
  error('expected explicit snapshot missing/stale state model')
end
if not matrix_source:find('Group identity is intentionally persistent', 1, true) then
  error('expected explicit matrix grouping persistence rationale in adapter comments')
end
if not topology_source:find('should_discover', 1, true) or not topology_source:find('forced_rescan_interval_ms', 1, true) then
  error('expected persistent topology cache with forced rescan policy')
end

print('energy_architecture_stability_regression_test.lua: ok')
