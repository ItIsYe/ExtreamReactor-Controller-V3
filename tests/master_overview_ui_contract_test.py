from pathlib import Path

text = Path('xreactor/master/ui/overview.lua').read_text(encoding='utf-8')

sections = [
    'Systemlage',
    'Steuerung',
    'Meldungen',
    'Kennzahlen',
    'Top-Nodes',
]
positions = []
for section in sections:
    pos = text.find(section)
    if pos == -1:
        raise SystemExit(f'missing overview section: {section}')
    positions.append(pos)

if positions != sorted(positions):
    raise SystemExit('overview section order is invalid')

print('master_overview_ui_contract_test.py: ok')
