from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
overlay = (ROOT / 'xreactor/nodes/fuel/half_overview.lua').read_text(encoding='utf-8')
assert 'DISABLED_FIXED_SCALE_1' in overlay
assert 'function M.render(_mon, _model) return false end' in overlay
for forbidden in ('mux.button', 'handle_touch', 'apply_valve(', '.transmit', 'begin_transaction('):
    assert forbidden not in overlay, forbidden
print('fuel_half_overview_contract_test.py: ok')
