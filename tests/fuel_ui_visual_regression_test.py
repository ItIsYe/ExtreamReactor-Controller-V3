from pathlib import Path
repo = Path(__file__).resolve().parents[1]
layout = (repo / 'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
router = (repo / 'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
monitor_scada = (repo / 'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
overlay = (repo / 'xreactor/nodes/fuel/half_overview.lua').read_text(encoding='utf-8')

assert 'local TARGET_W = 82' in monitor_scada
assert 'local TARGET_H = 40' in monitor_scada
assert 'local TARGET_SCALE = 1.0' in monitor_scada
assert 'M.SUPPORTED_SCALES = { 1.0 }' in monitor_scada
assert 'make_fullscreen_surface' not in monitor_scada
assert 'EXPECTED_W_HALF' not in monitor_scada
assert 'DISABLED_FIXED_SCALE_1' in overlay

for token in ('FUEL NODE - OVERVIEW', 'FUEL NODE - DETAILS', 'FUEL NODE - DIAGNOSTICS'):
    assert token in layout
assert 'NICHT KONFIGURIERT' in layout
assert 'REAKTORFLOTTE' in layout
assert 'NACHFUELLEN' in layout
assert 'ABKLINGZEIT' in layout
assert 'SCADA DATEN' in layout

for token in ('REAKTOR ROUTEN', 'REAKTOR BEARBEITEN', 'AKTIVE RT-MELDUNGEN', 'ERKANNTE PERIPHERALS', 'VENTILKETTE'):
    assert token in router
assert 'LIST_PER_PAGE = 8' in router
assert 'EDIT >' in router
assert 'compact_stepper' in router

print('fuel_ui_visual_regression_test.py: ok')
