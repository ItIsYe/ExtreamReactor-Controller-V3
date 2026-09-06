from pathlib import Path

support_runtime = Path('xreactor/nodes/support/runtime.lua').read_text(encoding='utf-8')
support_discovery = Path('xreactor/nodes/support/discovery.lua').read_text(encoding='utf-8')
for node in ('fuel', 'water', 'reprocessor'):
    source = Path(f'xreactor/nodes/{node}/main.lua').read_text(encoding='utf-8')
    assert 'config_normalizer' in source, f'{node}: expected dedicated config_normalizer wiring'
    assert 'role_descriptor' in source, f'{node}: expected role_descriptor wiring'
    # 2026-09-06: fuel/water/reprocessor use the decoupled fast/slow loop
    # split (nodes/support/runtime.lua's run_fast_loop()/run_slow_loop())
    # instead of the single-coroutine run_event_loop(), so a slow
    # discovery/export call can no longer block UI/touch/valve safety.
    assert 'support_runtime.run_fast_loop' in source, f'{node}: expected shared support fast-loop usage'
    assert 'support_runtime.run_slow_loop' in source, f'{node}: expected shared support slow-loop usage'
    assert 'support_ui_pages' in source, f'{node}: expected shared support ui_pages usage'
    assert 'support_command_handler' in source, f'{node}: expected shared support command handler usage'
    assert 'collect_devices_by_methods' in source, f'{node}: expected shared support discovery classification helper usage'

assert 'function M.init_logging' in support_runtime, 'expected shared support init_logging helper'
assert 'function M.run_event_loop' in support_runtime, 'expected shared support event loop helper'
assert 'function M.safe_wrapped_call' in support_runtime, 'expected shared safe wrapped call helper'
assert 'function M.collect_devices_by_methods' in support_discovery, 'expected shared discovery classification helper'
print('support_nodes_shared_runtime_regression_test.py: ok')
