from pathlib import Path

text = Path('xreactor/master/ui/overview.lua').read_text(encoding='utf-8')

sections = [
    'Systemstatus',
    'Globale Steuerung',
    'Aktive Meldungen',
    'KPI',
    'Node-Status'
]
positions = []
for section in sections:
    pos = text.find(section)
    if pos == -1:
        raise SystemExit(f'missing overview section: {section}')
    positions.append(pos)

if positions != sorted(positions):
    raise SystemExit('overview section order is invalid')

if 'render_status_line' not in text or 'render_controls' not in text:
    raise SystemExit('overview should use structured render helpers')

print('master_overview_ui_contract_test.py: ok')
