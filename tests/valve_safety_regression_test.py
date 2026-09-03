#!/usr/bin/env python3
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
main = (repo / 'xreactor/nodes/valve/main.lua').read_text(encoding='utf-8')
controller = (repo / 'xreactor/nodes/valve/controller.lua').read_text(encoding='utf-8')
router = (repo / 'xreactor/nodes/fuel/redstone_router.lua').read_text(encoding='utf-8')

assert 'require("nodes.valve.controller")' in main
assert 'controller:apply_valve(desired_high, true)' in main
assert 'on_quiesce = function() return controller:apply_valve(true, true) end' in main
# Feature (2026-09-03): redstone is now a fallback actuator, ONLY used when
# no sorter can be resolved at all (nodes/valve/controller.lua's
# _write_redstone_actuator(), gated by config.redstone_side). Whenever a
# sorter IS resolvable, every redstone side must be actively held low first
# (_disable_all_redstone_sides(), called unconditionally before the
# setAutoMode() write) so a sorter's own redstone input can never override
# the ejection state set via the Mekanism API.
assert 'redstone.setOutput' in controller
assert 'redstone.setOutput' not in main
assert 'self:_disable_all_redstone_sides()' in controller
disable_pos = controller.index('function M:_disable_all_redstone_sides()')
write_actuator_pos = controller.index('function M:_write_actuator(high)')
disable_call_pos = controller.index('self:_disable_all_redstone_sides()', write_actuator_pos)
set_auto_mode_pos = controller.index('sorter.setAutoMode', disable_call_pos)
assert disable_pos < write_actuator_pos < disable_call_pos < set_auto_mode_pos
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
