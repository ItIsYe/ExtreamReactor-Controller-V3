#!/usr/bin/env python3
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
main = (repo / 'xreactor/nodes/valve/main.lua').read_text(encoding='utf-8')
controller = (repo / 'xreactor/nodes/valve/controller.lua').read_text(encoding='utf-8')
router = (repo / 'xreactor/nodes/fuel/redstone_router.lua').read_text(encoding='utf-8')
valve_sources = main + controller

assert 'require("nodes.valve.controller")' in main
assert 'controller:apply_valve(desired_high, true)' in main
assert 'on_quiesce = function() return controller:apply_valve(true, true) end' in main
assert 'redstone.setOutput' not in valve_sources
assert 'setAutoMode' in controller
assert 'AUTO_MODE_READERS' in controller
assert 'self.sorter_device = nil' in controller
assert 'local applied = self:apply_valve(message.high, true)' in controller
assert 'local blocked_ok = self:apply_valve(true, true)' in controller

# Pairing follows complete command validation and a proven physical write.
src_pos = controller.index('if not valid_string(message.src) then')
id_pos = controller.index('if not valid_string(message.command_id) then')
value_pos = controller.index('if type(message.high) ~= "boolean" then')
apply_pos = controller.index('local applied = self:apply_valve(message.high, true)')
pair_pos = controller.index('self.config.trusted_source = message.src', apply_pos)
persist_pos = controller.index('self.utils.write_config(self.config_path, self.config)', pair_pos)
rollback_pos = controller.index('self.config.trusted_source = nil', persist_pos)
assert src_pos < id_pos < value_pos < apply_pos < pair_pos < persist_pos < rollback_pos

# Router command/ACK identity remains source+destination bound.
assert 'source_node_id = resolve_source_node_id(opts, router_config)' in router
assert 'message.src ~= entry.dst or message.dst ~= entry.src' in router
assert 'type = "SET_VALVE", src = entry.src, dst = entry.dst' in router

print('valve_safety_regression_test.py: ok')
