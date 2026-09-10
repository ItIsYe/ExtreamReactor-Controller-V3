from pathlib import Path
R=Path(__file__).resolve().parents[1]
f=(R/'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
v=(R/'xreactor/nodes/valve/local_ui.lua').read_text(encoding='utf-8')
assert 'local TARGET_SCALE = 1.0' in f and 'M.SUPPORTED_SCALES = { 1.0 }' in f
assert 'COMPACT_SCALE' not in f and 'make_fullscreen_surface' not in f
assert 'local COMPACT_SCALE = 0.5' in v
assert v.count('apply_valve(true, true)') == 1
assert 'apply_valve(false' not in v and '.transmit' not in v
print('ui_scale_modes_test.py: ok')
