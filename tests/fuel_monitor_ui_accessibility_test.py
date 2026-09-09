from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
monitor_scada = (ROOT / 'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
layout = (ROOT / 'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
router = (ROOT / 'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')

# Fixed native monitor contract: old 0.5 scaling transform is gone.
for token in ('local TARGET_W = 82', 'local TARGET_H = 40', 'local TARGET_SCALE = 1.0', 'M.FIXED_SCALE = true'):
    assert token in monitor_scada, token
for forbidden in ('COMPACT_SCALE', 'EXPECTED_W_HALF', 'EXPECTED_H_HALF', 'make_fullscreen_surface', 'window.create'):
    assert forbidden not in monitor_scada, forbidden

# Visible/touch footer rectangle is small and exact.
assert 'mux.button(mon, 3, 38, 15, "<< ZURUECK", "LIMITED", 2)' in monitor_scada
assert 'mux.button(mon, 65, 38, 15, "WEITER >>", "LIMITED", 2)' in monitor_scada

# 16 fixed visible slots, including placeholders.
assert 'local REACTORS_PER_PAGE = 16' in layout
assert 'local REACTOR_ROWS_PER_COLUMN = 8' in layout
assert 'NICHT KONFIGURIERT' in layout

# Router uses compact two-row buttons/7-cell steppers.
assert 'local button_w = 7' in router
assert 'mux.button(target, 2, 5, 14,' in router
assert 'mux.button(target, 57, 5, 22, "+ REAKTOR"' in router

print('fuel_monitor_ui_accessibility_test.py: ok')
