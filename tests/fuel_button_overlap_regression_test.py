from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
router = (ROOT / 'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
layout = (ROOT / 'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
footer = (ROOT / 'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')

# Smaller shared footer.
assert 'mux.button(mon, 3, 38, 15, "<< ZURUECK", "LIMITED", 2)' in footer
assert 'mux.button(mon, 65, 38, 15, "WEITER >>", "LIMITED", 2)' in footer

# Details and fleet navigation are compact two-row controls.
assert 'mux.button(mon, 3, 5, nav_w, "<< REAKTOR", "LIMITED", 2)' in layout
assert 'mux.button(mon, 67, 5, nav_w, "REAKTOR >>", "LIMITED", 2)' in layout
assert 'mux.button(mon, 3, nav_y, btn_w, "<< REAKTOR", "LIMITED", 2)' in layout
assert 'mux.button(mon, 67, nav_y, btn_w, "REAKTOR >>", "LIMITED", 2)' in layout

# Router controls no longer use the old oversized 3-row/full-width geometry.
for forbidden in (
    'mux.button(target, 2, 33, 50,',
    'mux.button(target, 53, 33, 28,',
    'local button_w = 11',
    'mux.button(target, 2, 32, 33, "FERTIG"',
    'mux.button(target, 2, 33, 79, "ABBRECHEN"',
):
    assert forbidden not in router, forbidden

for required in (
    'mux.button(target, 22, 33, 18,',
    'mux.button(target, 44, 33, 16, "VERWERFEN"',
    'local button_w = 7',
    'mux.button(target, 15, 31, 16, "FERTIG"',
    'mux.button(target, 33, 33, 16, "ABBRECHEN"',
):
    assert required in router, required

print('fuel_button_overlap_regression_test.py: ok')
