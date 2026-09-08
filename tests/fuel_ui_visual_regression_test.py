from pathlib import Path

repo = Path(__file__).resolve().parents[1]
main = (repo / 'xreactor/nodes/fuel/main.lua').read_text(encoding='utf-8')
monitor = (repo / 'xreactor/nodes/fuel/monitor_ui.lua').read_text(encoding='utf-8')
layout = (repo / 'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
router = (repo / 'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
monitor_scada = (repo / 'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')

assert 'local FUEL_MONITOR_SCALE = 1.0' in main
assert 'monitor_scada.ensure(mon)' in monitor
assert 'render_size_error' in monitor_scada
assert 'KEIN altes Fallback-Layout' in monitor_scada

# Four-screen visual contract.
for token in ('FUEL NODE - OVERVIEW', 'FUEL NODE - DETAILS', 'FUEL NODE - DIAGNOSTICS'):
    assert token in layout
assert 'REAKTOREN %d-%d VON %d' in layout
assert 'NACHFUELLEN UNTER' in layout
assert 'ABKLINGZEIT' in layout
assert 'SCADA DATEN' in layout

# Router has one consistent SCADA renderer for every submode.
for token in ('REAKTOR ROUTEN', 'REAKTOR BEARBEITEN', 'AKTIVE RT-MELDUNGEN', 'ERKANNTE PERIPHERALS', 'VENTILKETTE'):
    assert token in router
assert 'LIST_PER_PAGE = 8' in router
assert 'BEARB >' in router
assert 'VERWERFEN' in router

print('fuel_ui_visual_regression_test.py: ok')
