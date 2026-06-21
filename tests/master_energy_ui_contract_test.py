from pathlib import Path

text = Path('xreactor/master/ui/energy.lua').read_text(encoding='utf-8')

checks = [
    'Energy Summary',
    'Matrix / Storage',
    'Matrix-Detail',
    'Ressourcen',
    'Support-Nodes',
    'model.support_nodes',
]
for item in checks:
    if item not in text:
        raise SystemExit(f'missing energy contract fragment: {item}')

print('master_energy_ui_contract_test.py: ok')
