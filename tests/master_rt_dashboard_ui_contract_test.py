from pathlib import Path

text = Path('xreactor/master/ui/rt_dashboard.lua').read_text(encoding='utf-8')

checks = [
    'RT-Flotte',
    'Sequencer / Queue',
    'prioritized_rt_nodes(model.rt_nodes',
    'Soll %.1f',
    'Ist %.1f',
    'Queue: ',
]
for item in checks:
    if item not in text:
        raise SystemExit(f'missing RT contract fragment: {item}')

print('master_rt_dashboard_ui_contract_test.py: ok')
