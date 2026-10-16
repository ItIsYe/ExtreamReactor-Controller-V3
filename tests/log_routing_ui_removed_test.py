from pathlib import Path

support = Path("xreactor/nodes/support/ui_pages.lua").read_text(encoding="utf-8")
default_ui = Path("xreactor/nodes/log_collector/default_ui.lua").read_text(encoding="utf-8")
mockup_ui = Path("xreactor/nodes/log_collector/mockup_ui.lua").read_text(encoding="utf-8")

# Shared diagnostics may keep compatibility function names, but they must no
# longer render a selector or mutate the runtime log mode on touch.
if "utils_ref.get_log_mode" in support or "utils_ref.set_log_mode" in support:
    raise SystemExit("shared diagnostics still exposes log routing controls")
if 'target.write("Log:")' in support:
    raise SystemExit("shared diagnostics still draws the Log selector")

# LOG_COLLECTOR has two renderers. Neither may invoke the legacy selector or
# show a mode badge that could be mistaken for a routing control.
for name, text in (("default", default_ui), ("mockup", mockup_ui)):
    if "draw_log_mode_buttons(" in text:
        raise SystemExit(f"{name} LOG_COLLECTOR renderer still draws log routing controls")
if '"MODE " .. tostring(ctx.log_mode())' in mockup_ui:
    raise SystemExit("mockup LOG_COLLECTOR still displays the log routing mode badge")

print("log_routing_ui_removed_test.py: ok")
