from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
overlay = (ROOT / 'xreactor/nodes/fuel/half_overview.lua').read_text(encoding='utf-8')
valve = (ROOT / 'xreactor/nodes/valve/local_ui.lua').read_text(encoding='utf-8')
# tools/apply_patch.py is one-time delivery tooling for this package, not part
# of the ongoing codebase (same convention as fuel_scada_patch_contract_test.py
# from an earlier UI-scale package), so it isn't shipped in this repo -- the
# integration wiring it applied is checked against the actual runtime module
# it patched (monitor_ui.lua) instead.
monitor_ui = (ROOT / 'xreactor/nodes/fuel/monitor_ui.lua').read_text(encoding='utf-8')
monitor_scada = (ROOT / 'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')

# Native 0.5 overlay owns only the sparse physical middle area and no controls.
for token in (
    'local PHYSICAL_W = 164',
    'local PHYSICAL_H = 81',
    'local REGION_TOP = 25',
    'local REGION_BOTTOM = 72',
    'local SLOT_COUNT = 16',
    'local SLOTS_PER_COL = 8',
    'NICHT KONFIGURIERT',
    'draw_summary_box',
    'draw_box',
):
    assert token in overlay, token
for forbidden in ('mux.button', 'handle_touch', 'apply_valve(', 'set_logistics_enabled(',
                  'begin_transaction(', '.transmit', '_do_save('):
    assert forbidden not in overlay, forbidden

# Integration overlays only Overview, after the normal renderer has run, at
# ui_scale=0.5.
for token in (
    'local half_overview = require("nodes.fuel.half_overview")',
    'requested_scale == 0.5',
    'page.name == "Overview"',
    'pcall(half_overview.render, mon, model)',
):
    assert token in monitor_ui, token

# Footer nav buttons shrink under 0.5 fullscreen so they no longer look
# oversized once every draw call is physically doubled.
for token in (
    'binding and binding.scale == COMPACT_SCALE',
    'left_x, left_w = 4, 16',
    'right_w = 16',
):
    assert token in monitor_scada, token

# VALVE 0.5 remains one-way SAFE only, with the new centered narrower button.
for token in (
    'local COMPACT_ACTION_X = 8',
    'local COMPACT_ACTION_Y = 11',
    'local COMPACT_ACTION_W = 36',
    'local COMPACT_ACTION_H = 3',
    'MASTER: ONLINE',
    'READBACK: OK',
    'OEFFNEN NUR VIA FUEL',
):
    assert token in valve, token
assert valve.count('apply_valve(true, true)') == 1
assert 'apply_valve(false' not in valve
assert 'SET_VALVE' not in valve
assert '.transmit' not in valve

print('fuel_half_overview_contract_test.py: ok')
