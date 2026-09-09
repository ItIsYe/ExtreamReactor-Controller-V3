from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
router = (ROOT / "xreactor/nodes/fuel/router_scada.lua").read_text(encoding="utf-8")
layout = (ROOT / "xreactor/nodes/fuel/scada_layout.lua").read_text(encoding="utf-8")
footer = (ROOT / "xreactor/nodes/fuel/monitor_scada.lua").read_text(encoding="utf-8")

# Geometry helper: card bottom border is y + h - 1.
def bottom(y, h):
    return y + h - 1

# Reactor route list: paging controls y=29..31, card border must be row 32.
assert 'mux.card(target, 2, 9, 79, 24, { title = "REAKTOR ROUTEN"' in router
assert bottom(9, 24) == 32
assert 29 + 3 - 1 < 32

# Learn and chest picker: paging y=29..31, card border row 32.
assert 'mux.card(target, 2, 5, 79, 28, { title = "AKTIVE RT-MELDUNGEN"' in router
assert 'mux.card(target, 2, 5, 79, 28, { title = "ERKANNTE PERIPHERALS"' in router
assert bottom(5, 28) == 32
assert 29 + 3 - 1 < 32

# Valve path cards: paging y=28..30, both card borders row 31.
assert 'mux.card(target, 2, 9, 38, 23, { title = "AKTUELLE KETTE"' in router
assert 'mux.card(target, 43, 9, 38, 23, { title = "VENTIL ANFUEGEN"' in router
assert bottom(9, 23) == 31
assert 28 + 3 - 1 < 31

# Router bottom action rows end at 35; global page footer starts at 38.
for token in (
    'mux.button(target, 2, 33, 50,',
    'mux.button(target, 2, 33, 79, "ABBRECHEN"',
    'mux.button(target, 2, 33, 32, "FERTIG"',
):
    assert token in router, token
assert 33 + 3 - 1 == 35
assert 'mux.button(mon, left_x, 38, left_w, "<< ZURUECK", "LIMITED", 3)' in footer
assert 35 < 38

# Non-router page-local navigation also stays clear of the global footer.
assert 'local nav_y = 32' in layout               # Overview pagination: 32..34
assert 'mux.button(mon, 2, 6, nav_w, "<< REAKTOR", "LIMITED", 3)' in layout
assert 32 + 3 - 1 < 38
assert 6 + 3 - 1 < 10                             # Details content starts at row 10

# Horizontal control groups deliberately retain at least one blank column.
assert 'mux.button(target, 2, 5, 16,' in router   # x=2..17
assert 'mux.button(target, 19, 5, 37,' in router  # x=19..55
assert 'mux.button(target, 57, 5, 24,' in router  # x=57..80
assert 17 < 19 and 55 < 57

print("fuel_button_overlap_regression_test.py: ok")
