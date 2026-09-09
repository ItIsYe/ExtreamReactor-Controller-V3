from pathlib import Path

main = Path('xreactor/nodes/fuel/main.lua').read_text(encoding='utf-8')
monitor_ui = Path('xreactor/nodes/fuel/monitor_ui.lua').read_text(encoding='utf-8')
monitor_scada = Path('xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
layout = Path('xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
router_scada = Path('xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
ui_router = Path('xreactor/core/ui_router.lua').read_text(encoding='utf-8')

assert 'local FUEL_MONITOR_SCALE = config.ui_scale or 1.0' in main
assert 'monitor_scada.ensure(mon, requested_scale)' in monitor_ui
assert 'monitor_scada.touch_to_local' in monitor_ui
assert 'return monitor_scada.footer(target, center)' in monitor_ui
assert 'FALLBACK_UI_SCALE' not in monitor_ui
assert 'MIN_LARGE_WIDTH' not in monitor_ui
assert 'MIN_LARGE_HEIGHT' not in monitor_ui

assert 'local TARGET_W = 82' in monitor_scada
assert 'local TARGET_H = 40' in monitor_scada
assert 'local TARGET_SCALE = 1.0' in monitor_scada
assert 'local COMPACT_SCALE = 0.5' in monitor_scada
assert 'local EXPECTED_W_HALF = 164' in monitor_scada
assert 'local EXPECTED_H_HALF = 81' in monitor_scada
assert 'mux.button(mon, left_x, 38, left_w, "<< ZURUECK", "LIMITED", 3)' in monitor_scada
assert 'mux.button(mon, right_x, 38, right_w, "WEITER >>", "LIMITED", 3)' in monitor_scada
# Compact (0.5 fullscreen) mode narrows the footer buttons so the physically
# doubled rendering doesn't make them look oversized.
assert 'binding and binding.scale == COMPACT_SCALE' in monitor_scada
assert 'left_x, left_w = 4, 16' in monitor_scada
assert 'right_w = 16' in monitor_scada

assert 'REACTORS_PER_PAGE = 16' in layout
assert 'LIST_PER_PAGE = 8' in router_scada
assert 'legacy_overview' not in layout and 'legacy_details' not in layout
assert 'legacy_list' not in router_scada and 'legacy_edit' not in router_scada

# The shared router must preserve the visible footer's full 3-row rectangle.
assert 'y <= (prev.y2 or prev.y)' in ui_router
assert 'y <= (next_btn.y2 or next_btn.y)' in ui_router
assert 'y2 = page_footer.left.y2' in ui_router
assert 'y2 = page_footer.right.y2' in ui_router

print('fuel_monitor_ui_accessibility_test.py: ok')
