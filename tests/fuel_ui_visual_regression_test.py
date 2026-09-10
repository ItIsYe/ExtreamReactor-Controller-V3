from pathlib import Path
R=Path(__file__).resolve().parents[1]
l=(R/'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
r=(R/'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
m=(R/'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
h=(R/'xreactor/nodes/fuel/half_overview.lua').read_text(encoding='utf-8')
assert 'SUPPORTED_SCALES = { 1.0 }' in m and 'make_fullscreen_surface' not in m
assert 'DISABLED_FIXED_SCALE_1' in h
for t in ('FUEL NODE - OVERVIEW','FUEL NODE - DETAILS','FUEL NODE - DIAGNOSTICS','NICHT KONFIGURIERT','REAKTORFLOTTE','ABKLINGZEIT','SCADA DATEN'): assert t in l,t
for t in ('REAKTOR ROUTEN','REAKTOR BEARBEITEN','AKTIVE RT-MELDUNGEN','ERKANNTE PERIPHERALS','VENTILKETTE','stepper_card'): assert t in r,t
assert 'EDIT"' in r
print('fuel_ui_visual_regression_test.py: ok')
