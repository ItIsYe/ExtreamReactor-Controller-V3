#!/usr/bin/env python3
from pathlib import Path
repo=Path(__file__).resolve().parents[1]
valve=(repo/'xreactor/nodes/valve/main.lua').read_text(encoding='utf-8')
router=(repo/'xreactor/nodes/fuel/redstone_router.lua').read_text(encoding='utf-8')
assert 'local current_high = nil' in valve
assert 'apply_valve(desired_high)' in valve
assert 'local needs_block = (not valve_initialized) or current_high ~= true' in valve
assert 'actuator_initialized = valve_initialized' in valve
a=valve.index('if type(message.src) ~= "string" or message.src == "" then')
b=valve.index('if type(message.command_id) ~= "string" or message.command_id == "" then')
c=valve.index('if type(message.high) ~= "boolean" then')
p=valve.index('config.trusted_source = message.src')
assert a<p and b<p and c<p
assert 'source_node_id = resolve_source_node_id(opts, router_config)' in router
assert 'node_id = node_id' in (repo/'xreactor/nodes/fuel/main.lua').read_text(encoding='utf-8')
assert 'node_id = node_id' in (repo/'xreactor/nodes/reprocessor/main.lua').read_text(encoding='utf-8')
assert 'message.src ~= entry.dst or message.dst ~= entry.src' in router
assert 'type = "SET_VALVE", src = entry.src, dst = entry.dst' in router
print('valve_safety_regression_test.py: ok')
