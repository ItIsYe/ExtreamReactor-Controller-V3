from pathlib import Path
main=Path('xreactor/nodes/energy/main.lua').read_text(encoding='utf-8')
hb=Path('xreactor/nodes/energy/heartbeat.lua').read_text(encoding='utf-8')
required_main=['local heartbeat_mod          = require("nodes.energy.heartbeat")','local matrix_mod             = require("nodes.energy.matrix")','local function send_heartbeat_if_due','get_last_heartbeat_ts','services = service_manager.new({ log_prefix = "ENERGY" })','matrix_services = service_manager.new({ log_prefix = "ENERGY_MATRIX" })']
for t in required_main:
    if t not in main: raise AssertionError(f'missing ENERGY heartbeat-decoupling contract: {t}')
for t in ['send_heartbeat_if_due','get_last_heartbeat_ts','services:tick']:
    if t not in hb: raise AssertionError(f'heartbeat thread missing contract: {t}')
if 'matrix_services:tick' in hb: raise AssertionError('heartbeat thread must not tick blocking matrix services')
print('energy_heartbeat_decoupling_regression_test.py: ok')
