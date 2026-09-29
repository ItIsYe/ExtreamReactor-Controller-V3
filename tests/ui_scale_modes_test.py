from pathlib import Path
R=Path(__file__).resolve().parents[1]
f=(R/'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
v=(R/'xreactor/nodes/valve/local_ui.lua').read_text(encoding='utf-8')
assert 'local TARGET_SCALE = 1.0' in f and 'M.SUPPORTED_SCALES = { 1.0 }' in f
assert 'COMPACT_SCALE' not in f and 'make_fullscreen_surface' not in f
assert 'local COMPACT_SCALE = 0.5' in v
# Kein Aktorzugriff mehr aus der Oberflaeche, siehe
# tests/valve_local_ui_touch_test.lua.
assert 'apply_valve' not in v
assert '.transmit' not in v
print('ui_scale_modes_test.py: ok')
