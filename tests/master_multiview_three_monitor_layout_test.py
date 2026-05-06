from pathlib import Path

text = Path('xreactor/master/ui/multiview.lua').read_text(encoding='utf-8')

required = [
    'ROLE_MAP = { "overview", "rt", "energy" }',
    'if idx <= 3 then',
    'prior.locked = true',
    'ROLE_LABELS',
    'if not state or state.locked then return end'
]
for token in required:
    if token not in text:
        raise SystemExit(f'missing expected three-monitor contract token: {token}')

if text.find('ROLE_MAP') > text.find('function M:update_monitors'):
    raise SystemExit('ROLE_MAP should be declared before monitor assignment logic')

print('master_multiview_three_monitor_layout_test.py: ok')
