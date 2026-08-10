from pathlib import Path
s=Path('xreactor/master/ui/rt_dashboard.lua').read_text(encoding='utf-8')
for t in ['RT FLEET','RT-FLOTTE','SEQUENCER / QUEUE','prioritized_rt_nodes(model.rt_nodes','QUEUE / SD','shutdown_verdict(rt)']:
    if t not in s: raise AssertionError(f'missing current RT dashboard contract: {t}')
print('master_rt_dashboard_ui_contract_test.py: ok')
