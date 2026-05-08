from pathlib import Path

text = Path('xreactor/master/ui/multiview.lua').read_text(encoding='utf-8')

required = [
    'PRIMARY_ROLE_MAP = { "overview", "rt", "energy" }',
    'if idx <= 3 then',
    'prior.locked = true',
    'ROLE_LABELS',
    'if not state or state.locked then return end'
]
for token in required:
    if token not in text:
        raise SystemExit(f'missing expected three-monitor contract token: {token}')

if text.find('PRIMARY_ROLE_MAP') > text.find('function M:update_monitors'):
    raise SystemExit('PRIMARY_ROLE_MAP should be declared before monitor assignment logic')

if 'prior.mode = "aux_cycle"' not in text or 'state.view = self.view_order[(current % #self.view_order) + 1]' not in text:
    raise SystemExit('aux monitor cycle contract missing')

print('master_multiview_three_monitor_layout_test.py: ok')
