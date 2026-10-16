from pathlib import Path
R=Path(__file__).resolve().parents[1]
router=(R/'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
layout=(R/'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
footer=(R/'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
assert 'mux.button(mon, 3, 38, 13, "<< ZURUECK", "LIMITED", 2)' in footer
assert 'mux.button(mon, 67, 38, 13, "WEITER >>", "LIMITED", 2)' in footer
for t in (
  'mux.button(mon, 4, 33, 12, "<< REAKTOR", "LIMITED", 2)',
  'mux.button(mon, 67, 33, 12, "REAKTOR >>", "LIMITED", 2)',
  'mux.button(mon, 4, 6, 12, "<< REAKTOR", "LIMITED", 2)',
  'mux.button(mon, 67, 6, 12, "REAKTOR >>", "LIMITED", 2)',
): assert t in layout,t
for t in (
  'mux.button(target, 72, y, 7, "EDIT", "LIMITED", 1)',
  'local button_w = 6',
  'mux.button(target, 24, 33, 15,',
  'mux.button(target, 44, 33, 15, "VERWERFEN"',
  'mux.button(target, 18, 31, 14, "FERTIG"',
  'mux.button(target, 68, y, 11, "EINLERNEN", "OK", 1)',
  'mux.button(target, 35, py, 3, "X", "WARNING", 1)',
  'mux.button(target, 76, vy, 3, "+", "OK", 1)',
): assert t in router,t
for bad in ('local button_w = 11','mux.button(target, 2, 33, 50,','mux.button(target, 53, 33, 28,'):
    assert bad not in router,bad
print('fuel_button_overlap_regression_test.py: ok')
