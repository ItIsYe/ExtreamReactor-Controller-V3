# valve_local_ui_contract_test.py: verifies the fixed-51x19 local VALVE
# terminal UI's safety contract on the actual runtime modules. The original
# integration package also shipped a one-time tools/apply_patch.py
# installer script with its own BASE_COMMIT/BASE_MAIN_BLOB text-anchor
# assertions -- that script is delivery tooling, not part of the ongoing
# codebase, so it was not copied into this repo (same convention as
# tests/fuel_scada_patch_contract_test.py) and those assertions are dropped
# here. The equivalent runtime behavior is still covered: the constants and
# safety invariants below against the real local_ui.lua, and the wiring
# against the real main.lua.

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / 'xreactor/nodes/valve/local_ui.lua').read_text(encoding='utf-8')
main_lua = (ROOT / 'xreactor/nodes/valve/main.lua').read_text(encoding='utf-8')

# Fixed terminal geometry.
for needle in (
    'local EXPECTED_W = 51',
    'local EXPECTED_H = 19',
):
    assert needle in ui, needle

# Seit 2026-09-29 hat diese Oberflaeche ueberhaupt keine Bedienung mehr
# (Betreiberwunsch: der lokale Sperrknopf soll raus). Das ist strenger als
# die frueher hier gepruefte Einbahn-Regel "darf nur BLOCKIEREN": geprueft
# wird jetzt, dass gar kein Weg zum Aktor mehr existiert -- weder ein
# gezeichneter Knopf, noch eine stehengebliebene Trefferflaeche, noch ein
# direkter Aufruf. Verhalten dazu: tests/valve_local_ui_touch_test.lua.
assert 'mux.button' not in ui
assert 'safe_button' not in ui
assert 'apply_valve' not in ui
assert 'current_high = false' not in ui
assert 'SET_VALVE' not in ui

# HOP status is read-only UI state -- it must never scan or transmit itself.
for needle in (
    'get_hop_status', 'HOP', 'last_scan_ms', 'interval_s', 'modem_ready',
    '"STALE"', '"AUS"', '"FEHLER"', '"AKTIV"',
):
    assert needle in ui, needle
assert 'hop_reporter:scan' not in ui
assert 'HOP_SCAN' in ui  # text only; no transmit/control path
assert '.transmit' not in ui

# Bei falscher Terminalgroesse sagt die Oberflaeche das auch.
assert 'ANZEIGE' in ui and 'NICHT MOEGLICH' in ui

# Der Ventilzustand muss sichtbar bleiben -- die Aussage steckte vorher in
# der Farbe des Knopfs und darf mit ihm nicht verschwunden sein.
for needle in ('valve_state_text', 'valve_state_key', '"BLOCKIERT"', '"OFFEN"'):
    assert needle in ui, needle

# main.lua wiring: der Event-Pfad der lokalen UI bleibt in der fast-Gruppe
# (er traegt nur noch term_resize), das Zeichnen in der slow-Gruppe (siehe
# nodes/valve/main.lua), und der passive hop_reporter bleibt main.lua's
# eigener -- die UI bekommt nur einen lesenden Schnappschuss ueber
# get_hop_status(), nie den Reporter selbst.
for needle in (
    'local valve_local_ui = require("nodes.valve.local_ui")',
    'name = "valve_local_ui_input"',
    'name = "valve_local_ui_render"',
    'get_hop_status = function()',
    'enabled = hop_reporter:is_enabled()',
    'last_scan_ms = last_hop_scan_ms',
):
    assert needle in main_lua, needle

# Text mockup: exactly 51 x 19 (sanity-checks the reference render shipped
# alongside this test, if still present in the repo history/uploads dir --
# skipped here since mockups/ is delivery material, not runtime code).

print('valve_local_ui_contract_test.py: ok')
