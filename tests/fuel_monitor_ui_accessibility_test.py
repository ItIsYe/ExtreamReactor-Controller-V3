from pathlib import Path

monitor_text = Path("xreactor/nodes/fuel/monitor_ui.lua").read_text(encoding="utf-8")
details_text = Path("xreactor/nodes/fuel/ui_completion.lua").read_text(encoding="utf-8")

monitor_required = [
    "local PREFERRED_UI_SCALE = 1.0",
    "local FALLBACK_UI_SCALE = 0.5",
    "local MIN_LARGE_WIDTH = 40",
    "local MIN_LARGE_HEIGHT = 18",
    "ensure_readable_scale(ctx, mon)",
    '"[ << ZURUECK ]"',
    '"[ WEITER >> ]"',
    'page_with_large_footer(fuel_ui.render_overview, "FUEL OVERVIEW")',
    'page_with_large_footer(fuel_ui.render_details, "FUEL DETAILS")',
    'page_with_large_footer(fuel_ui.render_diagnostics, "FUEL DIAGNOSTICS")',
    'return large_footer(target, "ROUTER")',
]

details_required = [
    '"[ << REAKTOR ]"',
    '"[ REAKTOR >> ]"',
    "state.details_prev = state.details_index > 1",
    "state.details_next = state.details_index < #reactors",
]

missing = [needle for needle in monitor_required if needle not in monitor_text]
missing += [needle for needle in details_required if needle not in details_text]
if missing:
    raise SystemExit("FUEL accessibility wiring missing: " + ", ".join(missing))

print("fuel_monitor_ui_accessibility_test.py: ok")
