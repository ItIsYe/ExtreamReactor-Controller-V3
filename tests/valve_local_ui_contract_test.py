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
    'local ACTION_X = 2',
    'local ACTION_Y = 14',
    'local ACTION_W = 48',
    'local ACTION_H = 3',
):
    assert needle in ui, needle

# Visible rectangle and hit-test must share mux.button() geometry including y2.
assert 'self.safe_button = mux.button' in ui
assert 'y <= (rect.y2 or rect.y)' in ui

# Safety invariant: local UI can ONLY force BLOCKED, never OPEN.
assert ui.count('apply_valve(true, true)') == 1
assert 'apply_valve(false' not in ui
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

# Wrong terminal size must disable stale local controls.
assert 'self.safe_button = nil' in ui
assert 'LOKALE AKTIONEN' in ui and 'DEAKTIVIERT' in ui

# main.lua wiring: local UI input stays in the fast group, rendering in the
# slow group (see nodes/valve/main.lua's own comment on that split), and the
# passive hop_reporter remains main.lua's own -- the UI only ever gets a
# read-only snapshot via get_hop_status(), never the reporter itself.
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
