# fuel_scada_patch_contract_test.py: verifies the fixed-82x40 SCADA
# presentation contract on the actual runtime modules. The original
# integration package also shipped a one-time tools/apply_patch.py
# installer script with its own text-anchor assertions (FUEL_MONITOR_SCALE
# replacement, ui_router.lua y2 anchors) -- that script is delivery tooling,
# not part of the ongoing codebase, so it was not copied into this repo and
# those assertions are dropped here. The equivalent runtime behavior (fixed
# 82x40, y2-aware footer hit-testing) is still covered: the constants below
# against the real modules, and core/ui_router.lua's y2 support against its
# own dedicated tests.

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
layout = (ROOT / 'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
router = (ROOT / 'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
monitor = (ROOT / 'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
completion = (ROOT / 'xreactor/nodes/fuel/ui_completion.lua').read_text(encoding='utf-8')
ui_pages = (ROOT / 'xreactor/nodes/fuel/ui_pages.lua').read_text(encoding='utf-8')

# Fixed-size contract: no legacy/responsive fallback in the new runtime.
for text, name in ((layout, 'scada_layout'), (router, 'router_scada'), (monitor, 'monitor_scada')):
    assert 'TARGET_W = 82' in text, name
    assert 'TARGET_H = 40' in text, name

for forbidden in ('legacy_overview', 'legacy_details', 'legacy_list', 'legacy_edit', 'MIN_WIDE_W', 'FALLBACK_UI_SCALE'):
    assert forbidden not in layout + router + monitor + completion + ui_pages, f'legacy fallback token remains: {forbidden}'
assert 'render_overview' not in completion, 'old Overview renderer must not remain in ui_completion.lua'
assert 'render_details' not in completion, 'old Details renderer must not remain in ui_completion.lua'
assert 'render_diagnostics' not in ui_pages, 'old Diagnostics renderer must not remain in ui_pages.lua'
assert 'scada_layout.attach(instance' in completion

monitor_ui = (ROOT / 'xreactor/nodes/fuel/monitor_ui.lua').read_text(encoding='utf-8')
main_lua = (ROOT / 'xreactor/nodes/fuel/main.lua').read_text(encoding='utf-8')
assert 'local FUEL_MONITOR_SCALE = 1.0' in main_lua
assert 'monitor_scada.ensure(mon)' in monitor_ui
assert 'monitor_scada.footer(target, center)' in monitor_ui

# Shared router must preserve optional y2 and hit the full visible rectangle.
ui_router = (ROOT / 'xreactor/core/ui_router.lua').read_text(encoding='utf-8')
assert 'y <= (prev.y2 or prev.y)' in ui_router
assert 'y <= (next_btn.y2 or next_btn.y)' in ui_router
assert 'y2 = page_footer.left.y2' in ui_router
assert 'y2 = page_footer.right.y2' in ui_router

# SCADA boundary: no operational control module is imported/called here.
for text, name in ((layout, 'scada_layout'), (router, 'router_scada'), (monitor, 'monitor_scada')):
    for token in (
        'require("nodes.fuel.logistics_router")',
        'require("nodes.fuel.redstone_router")',
        'require("services.comms_service")',
        'set_logistics_enabled(',
        '_do_save(',
        'begin_transaction(',
        'record_export(',
    ):
        assert token not in text, f'{name} crosses presentation/control boundary via {token}'

# All router modes are overridden: no runtime path to the old renderer.
for mode in ('_render_list', '_render_edit', '_render_learn', '_render_chest_pick', '_render_path'):
    assert f'router.{mode} = function' in router, mode

print('fuel_scada_patch_contract_test.py: ok')
