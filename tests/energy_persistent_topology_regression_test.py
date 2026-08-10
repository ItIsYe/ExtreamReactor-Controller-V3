from pathlib import Path
main=Path('xreactor/nodes/energy/main.lua').read_text(encoding='utf-8')
disc=Path('xreactor/nodes/energy/discovery_runtime.lua').read_text(encoding='utf-8')
cache=Path('xreactor/nodes/energy/matrix_topology_cache.lua').read_text(encoding='utf-8')
snap=Path('xreactor/nodes/energy/matrix_snapshot_runtime.lua').read_text(encoding='utf-8')
for t in ['matrix_topology_cache.new','topology_cache = topology_cache','on_topology_changed','discovery_force_rescan_interval']:
    if t not in main: raise AssertionError(f'main missing topology contract: {t}')
for t in ['topology_cache','matrix_runtime','matrix_groups']:
    if t not in disc: raise AssertionError(f'discovery runtime missing topology integration: {t}')
for t in ['forced_rescan_interval','peripheral_detach']:
    if t not in cache: raise AssertionError(f'topology cache missing invalidation contract: {t}')
for t in ['last_good_state','stale']:
    if t not in snap: raise AssertionError(f'matrix snapshot missing freshness contract: {t}')
print('energy_persistent_topology_regression_test.py: ok')
