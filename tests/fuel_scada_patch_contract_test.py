from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
layout = (ROOT / 'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
router = (ROOT / 'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
monitor = (ROOT / 'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
completion = (ROOT / 'xreactor/nodes/fuel/ui_completion.lua').read_text(encoding='utf-8') if (ROOT / 'xreactor/nodes/fuel/ui_completion.lua').exists() else ''
ui_pages = (ROOT / 'xreactor/nodes/fuel/ui_pages.lua').read_text(encoding='utf-8') if (ROOT / 'xreactor/nodes/fuel/ui_pages.lua').exists() else ''

for text, name in ((layout, 'scada_layout'), (router, 'router_scada'), (monitor, 'monitor_scada')):
    assert 'TARGET_W = 82' in text, name
    assert 'TARGET_H = 40' in text, name

assert 'TARGET_SCALE = 1.0' in monitor
assert 'SUPPORTED_SCALES = { 1.0 }' in monitor
for forbidden in ('make_fullscreen_surface', 'EXPECTED_W_HALF', 'COMPACT_SCALE', 'legacy_overview', 'legacy_details'):
    assert forbidden not in monitor + layout + router, forbidden

# Shared router hit-testing must preserve optional y2.
ui_router_path = ROOT / 'xreactor/core/ui_router.lua'
if ui_router_path.exists():
    ui_router = ui_router_path.read_text(encoding='utf-8')
    assert 'y <= (prev.y2 or prev.y)' in ui_router
    assert 'y <= (next_btn.y2 or next_btn.y)' in ui_router

# Presentation/control boundary.
for text, name in ((layout, 'scada_layout'), (router, 'router_scada'), (monitor, 'monitor_scada')):
    for token in (
        'require("nodes.fuel.logistics_router")',
        'require("nodes.fuel.redstone_router")',
        'require("services.comms_service")',
        'set_logistics_enabled(', '_do_save(', 'begin_transaction(', 'record_export(',
    ):
        assert token not in text, f'{name} crosses presentation/control boundary via {token}'

for mode in ('_render_list', '_render_edit', '_render_learn', '_render_chest_pick', '_render_path'):
    assert f'router.{mode} = function' in router, mode

print('fuel_scada_patch_contract_test.py: ok')
