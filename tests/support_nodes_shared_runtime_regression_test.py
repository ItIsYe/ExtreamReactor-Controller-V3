from pathlib import Path

support_runtime = Path('xreactor/nodes/support/runtime.lua').read_text(encoding='utf-8')
for node in ('fuel', 'water', 'reprocessor'):
    source = Path(f'xreactor/nodes/{node}/main.lua').read_text(encoding='utf-8')
    assert 'config_normalizer' in source, f'{node}: expected dedicated config_normalizer wiring'
    assert 'role_descriptor' in source, f'{node}: expected role_descriptor wiring'
    assert 'support_runtime.run_event_loop' in source, f'{node}: expected shared support runtime event loop usage'

assert 'function M.init_logging' in support_runtime, 'expected shared support init_logging helper'
assert 'function M.run_event_loop' in support_runtime, 'expected shared support event loop helper'
print('support_nodes_shared_runtime_regression_test.py: ok')
