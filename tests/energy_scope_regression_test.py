from pathlib import Path
s=Path('xreactor/nodes/energy/main.lua').read_text(encoding='utf-8')
required=['local role_logic             = require("nodes.support.role_logic")','role_logic.master_peer_state(comms, constants.roles.MASTER)','role_logic.is_master_connected({','last_seen_ts = runtime.master_seen_ts']
for t in required:
    if t not in s: raise AssertionError(f'missing current ENERGY master-scope contract: {t}')
if 'local master_peer_state' in s or 'local is_master_connected' in s:
    raise AssertionError('ENERGY must use shared role_logic directly rather than shadowed forward declarations')
print('energy_scope_regression_test.py: ok')
