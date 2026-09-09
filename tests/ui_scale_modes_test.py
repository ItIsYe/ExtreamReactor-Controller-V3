from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
fuel_scada = (ROOT / 'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
valve_ui = (ROOT / 'xreactor/nodes/valve/local_ui.lua').read_text(encoding='utf-8')

# FUEL intentionally returned to one native scale for reliable proportions.
assert 'local TARGET_SCALE = 1.0' in fuel_scada
assert 'M.SUPPORTED_SCALES = { 1.0 }' in fuel_scada
assert 'function M.normalize_scale(_value)' in fuel_scada
assert 'return TARGET_SCALE' in fuel_scada
assert 'COMPACT_SCALE' not in fuel_scada
assert 'EXPECTED_W_HALF' not in fuel_scada
assert 'make_fullscreen_surface' not in fuel_scada

# VALVE keeps its current compact-density option; its built-in terminal cannot
# physically change text scale, and the one-way SAFE invariant remains.
assert 'local COMPACT_SCALE = 0.5' in valve_ui
assert '_render_compact_frame' in valve_ui
assert valve_ui.count('apply_valve(true, true)') == 1
assert 'apply_valve(false' not in valve_ui
assert '.transmit' not in valve_ui

print('ui_scale_modes_test.py: ok')
