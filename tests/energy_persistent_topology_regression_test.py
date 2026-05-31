from pathlib import Path

main_source = Path('xreactor/nodes/energy/main.lua').read_text(encoding='utf-8')
service_source = Path('xreactor/services/discovery_service.lua').read_text(encoding='utf-8')
runtime_source = Path('xreactor/nodes/energy/matrix_snapshot_runtime.lua').read_text(encoding='utf-8')
cache_source = Path('xreactor/nodes/energy/matrix_topology_cache.lua').read_text(encoding='utf-8')

required_main = [
    'matrix_topology_cache',
    'reconcile_matrix_groups',
    'topology_cache:should_discover',
    'discovery_force_rescan_interval',
    'if topology_changed then',
]
for snippet in required_main:
    if snippet not in main_source:
        raise AssertionError(f'missing main snippet: {snippet}')

for snippet in [
    'should_discover = opts.should_discover',
    'local due = ts - self.last_scan >= self.interval * 1000',
]:
    if snippet not in service_source:
        raise AssertionError(f'missing discovery service snippet: {snippet}')

for snippet in ['last_good_state', 'missing =', 'stale =']:
    if snippet not in runtime_source:
        raise AssertionError(f'missing runtime snippet: {snippet}')

for snippet in ['forced_rescan_interval_ms', 'peripheral_detach']:
    if snippet not in cache_source:
        raise AssertionError(f'missing topology cache snippet: {snippet}')

print('energy_persistent_topology_regression_test.py: ok')
