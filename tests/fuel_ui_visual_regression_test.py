from pathlib import Path

# Regression coverage for the four in-game FUEL screenshots: readable scale,
# actionable empty states, visible EDIT routing entry, and uncluttered diagnostics.
repo = Path(__file__).resolve().parents[1]
main = (repo / "xreactor/nodes/fuel/main.lua").read_text(encoding="utf-8")
monitor_ui = (repo / "xreactor/nodes/fuel/monitor_ui.lua").read_text(encoding="utf-8")
ui_pages = (repo / "xreactor/nodes/fuel/ui_pages.lua").read_text(encoding="utf-8")
ui_completion = (repo / "xreactor/nodes/fuel/ui_completion.lua").read_text(encoding="utf-8")
router = (repo / "xreactor/nodes/fuel/router_ui.lua").read_text(encoding="utf-8")
responsive = (repo / "xreactor/nodes/fuel/router_ui_responsive.lua").read_text(encoding="utf-8")
mockup = (repo / "xreactor/core/mockup_ui.lua").read_text(encoding="utf-8")

assert "local FUEL_MONITOR_SCALE = 0.5" in main
assert main.count('monitor_adapter.find(nil, "first", FUEL_MONITOR_SCALE, CONFIG.LOG_PREFIX)') == 2
assert "for peer_id, peer in pairs(comms:get_peers() or {}) do" in main
assert "peer.role == constants.roles.RT_NODE" in main
assert "for _, peer in ipairs(comms:get_peers())" not in main

assert "ui_diagnostics_overlay.attach" not in monitor_ui
assert 'require("nodes.fuel.ui_diagnostics_overlay")' not in monitor_ui
assert "err=%d" in ui_pages
assert "NAECHSTER SCHRITT" in ui_completion
assert "ROUTER > EDIT" in ui_completion
assert "inset = 3" in ui_completion

render_start = router.index("function M:render(")
render_end = router.index("function M:handle_touch", render_start)
render_body = router[render_start:render_end]
assert render_body.rfind("self:_render_mode_tabs") > render_body.rfind("self:_render_tree")
assert "empty_edit_btn" in router
assert "[ EDIT ROUTEN ]" in router
assert "if hit(u.edit_btn) or hit(u.empty_edit_btn) then" in router
assert "inset = 3" in render_body
assert "Keine Reaktor-Ziele gefunden" in responsive
assert "opts.inset" in mockup
print("fuel_ui_visual_regression_test.py: ok")
