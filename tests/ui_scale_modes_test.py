from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
fuel_main = (ROOT / "xreactor/nodes/fuel/main.lua").read_text(encoding="utf-8")
fuel_cfg = (ROOT / "xreactor/nodes/fuel/config.lua").read_text(encoding="utf-8")
fuel_norm = (ROOT / "xreactor/nodes/fuel/config_normalizer.lua").read_text(encoding="utf-8")
fuel_scada = (ROOT / "xreactor/nodes/fuel/monitor_scada.lua").read_text(encoding="utf-8")
fuel_monitor = (ROOT / "xreactor/nodes/fuel/monitor_ui.lua").read_text(encoding="utf-8")
valve_main = (ROOT / "xreactor/nodes/valve/main.lua").read_text(encoding="utf-8")
valve_cfg = (ROOT / "xreactor/nodes/valve/config.lua").read_text(encoding="utf-8")
valve_ui = (ROOT / "xreactor/nodes/valve/local_ui.lua").read_text(encoding="utf-8")

assert "ui_scale = 0.5" in fuel_main
assert "DEFAULT_UI_SCALE = 0.5" in fuel_cfg
assert "ui_scale ~= 0.5 and ui_scale ~= 1.0" in fuel_norm
assert "local FUEL_MONITOR_SCALE = config.ui_scale or 1.0" in fuel_main
assert "local COMPACT_SCALE = 0.5" in fuel_scada
assert "local EXPECTED_W_HALF = 164" in fuel_scada
assert "local EXPECTED_H_HALF = 81" in fuel_scada
assert "make_fullscreen_surface" in fuel_scada
assert "physical_render_h = HALF_RENDER_H" in fuel_scada
assert "touch_to_local" in fuel_scada
# window.create(...)-based centering (the old dead-border approach) is gone;
# the fullscreen scaling surface (make_fullscreen_surface, checked above) is
# the only 0.5-mode mechanism. Not checked by banning the phrase "centered
# 82x40 viewport" -- the module's own header comment legitimately mentions
# that historical approach for contrast when explaining the fix.
assert "window.create(mon, x, y, TARGET_W, TARGET_H" not in fuel_scada
assert "monitor_scada.ensure(mon, requested_scale)" in fuel_monitor
assert "monitor_scada.touch_to_local" in fuel_monitor

assert "ui_scale = 0.5" in valve_main
assert "ui_scale        = 0.5" in valve_cfg
assert "valve_ui_scale ~= 0.5 and valve_ui_scale ~= 1.0" in valve_main
assert "ui_scale = config.ui_scale" in valve_main
assert "local COMPACT_SCALE = 0.5" in valve_ui
assert "_render_compact_frame" in valve_ui
assert "local COMPACT_ACTION_X = 6" in valve_ui
assert "local COMPACT_ACTION_Y = 11" in valve_ui
assert "local COMPACT_ACTION_W = 40" in valve_ui
assert "Rows 18..19 intentionally blank" in valve_ui
assert valve_ui.count("apply_valve(true, true)") == 1
assert "apply_valve(false" not in valve_ui
assert "SET_VALVE" not in valve_ui
assert ".transmit" not in valve_ui
print("ui_scale_modes_test.py: ok")
