#!/usr/bin/env python3
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
valve = (repo / 'xreactor/nodes/valve/main.lua').read_text(encoding='utf-8')
router = (repo / 'xreactor/nodes/fuel/redstone_router.lua').read_text(encoding='utf-8')

assert 'local current_high = nil' in valve
assert 'local function apply_valve(high, force_physical)' in valve
assert 'apply_valve(desired_high, true)' in valve
assert 'on_quiesce = function() return apply_valve(true, true) end' in valve
assert 'apply_valve(message.high, true)' in valve  # duplicate ACK path re-proves hardware
assert 'apply_valve(true, true)' in valve  # failsafe/pair rollback force a physical BLOCKED write
assert 'actuator_initialized = valve_initialized' in valve

# Pairing is allowed only after complete command validation and successful
# actuator application; a persistence failure must undo RAM trust.
a = valve.index('if type(message.src) ~= "string" or message.src == "" then')
b = valve.index('if type(message.command_id) ~= "string" or message.command_id == "" then')
c = valve.index('if type(message.high) ~= "boolean" then')
apply_pos = valve.index('local applied = apply_valve(message.high', c)
pair_pos = valve.index('config.trusted_source = message.src', apply_pos)
persist_pos = valve.index('utils.write_config(CONFIG.CONFIG_PATH, config)', pair_pos)
assert a < apply_pos and b < apply_pos and c < apply_pos < pair_pos < persist_pos
assert valve.index('config.trusted_source = nil', persist_pos) > persist_pos

# Router command/ACK identity remains source+destination bound.
assert 'source_node_id = resolve_source_node_id(opts, router_config)' in router
assert 'node_id = node_id' in (repo / 'xreactor/nodes/fuel/main.lua').read_text(encoding='utf-8')
assert 'node_id = node_id' in (repo / 'xreactor/nodes/reprocessor/main.lua').read_text(encoding='utf-8')
assert 'message.src ~= entry.dst or message.dst ~= entry.src' in router
assert 'type = "SET_VALVE", src = entry.src, dst = entry.dst' in router

print('valve_safety_regression_test.py: ok')
