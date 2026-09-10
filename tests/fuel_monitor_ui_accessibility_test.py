from pathlib import Path
R=Path(__file__).resolve().parents[1]
m=(R/'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
l=(R/'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
r=(R/'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
for t in ('local TARGET_W = 82','local TARGET_H = 40','local TARGET_SCALE = 1.0','M.FIXED_SCALE = true'): assert t in m,t
for bad in ('COMPACT_SCALE','EXPECTED_W_HALF','make_fullscreen_surface','window.create'): assert bad not in m,bad
assert 'mux.button(mon, 3, 38, 13, "<< ZURUECK", "LIMITED", 2)' in m
assert 'local REACTORS_PER_PAGE = 16' in l and 'NICHT KONFIGURIERT' in l
assert 'local button_w = 6' in r
assert 'mux.button(target, 72, y, 7, "EDIT", "LIMITED", 1)' in r
print('fuel_monitor_ui_accessibility_test.py: ok')
