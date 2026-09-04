from pathlib import Path

# Regression coverage for the four in-game FUEL screenshots: readable scale,
# actionable empty states, visible EDIT routing entry, and uncluttered diagnostics.
repo = Path(__file__).resolve().parents[1]
main = (repo / "xreactor/nodes/fuel/main.lua").read_text(encoding="utf-8")
monitor_ui = (repo / "xreactor/nodes/fuel/monitor_ui.lua").read_text(encoding="utf-8")
ui_pages = (repo / "xreactor/nodes/fuel/ui_pages.lua").read_text(encoding="utf-8")
ui_completion = (repo / "xreactor/nodes/fuel/ui_completion.lua").read_text(encoding="utf-8")
router = (repo / "xreactor/nodes/fuel/router_ui.lua").read_text(encoding="utf-8")
reactor_targets = (repo / "xreactor/nodes/fuel/reactor_targets.lua").read_text(encoding="utf-8")
mockup = (repo / "xreactor/core/mockup_ui.lua").read_text(encoding="utf-8")

assert "local FUEL_MONITOR_SCALE = 0.5" in main
assert "local FUEL_MONITOR_SCALE = 1.0" not in main
assert main.count('monitor_adapter.find(nil, "first", FUEL_MONITOR_SCALE, CONFIG.LOG_PREFIX)') == 2
assert 'require("nodes.fuel.reactor_targets")' in main
assert "reactor_targets.collect(config, fuel_status_cache)" in main
assert "get_peers" not in reactor_targets  # An RT peer is not a routable reactor.
assert "global_reactor_id" in reactor_targets

assert "ui_diagnostics_overlay.attach" not in monitor_ui
assert 'require("nodes.fuel.ui_diagnostics_overlay")' not in monitor_ui
assert "ERR%d" in ui_pages
assert "NAECHSTER SCHRITT" in ui_completion
assert "ROUTER > REAKTOR EINLERNEN" in ui_completion
assert "ROUTER > EINLERNEN" in ui_completion
assert "inset = 3" in ui_completion

# 2026-09-04: das alte TREE/EDIT-Tabpaar ist einem einzelnen Hauptbildschirm
# (u.mode: list/learn/edit/inlet_pick/path) gewichen -- kein manuell
# getippter Reaktorname mehr, sondern EINLERNEN aus einer echten,
# live-meldenden RT-Node.
render_start = router.index("function M:render(")
render_end = router.index("function M:handle_touch", render_start)
render_body = router[render_start:render_end]
assert "u.mode == \"learn\"" in render_body
assert "u.mode == \"edit\"" in render_body
assert "u.mode == \"path\"" in render_body
assert "learn_btn" in router
assert "REAKTOR EINLERNEN" in router
assert "Keine Reaktoren konfiguriert" in router
assert "opts.inset" in mockup
print("fuel_ui_visual_regression_test.py: ok")
