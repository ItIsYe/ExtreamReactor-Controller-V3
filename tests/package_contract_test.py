from pathlib import Path
R=Path(__file__).resolve().parents[1]
l=(R/'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
r=(R/'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
m=(R/'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
v=(R/'xreactor/nodes/valve/local_ui.lua').read_text(encoding='utf-8')
h=(R/'xreactor/nodes/fuel/half_overview.lua').read_text(encoding='utf-8')
assert 'Complete native 82x40 rewrite' in l and 'Complete native 82x40 rewrite' in r
assert 'M.SUPPORTED_SCALES = { 1.0 }' in m and 'M.FOOTER_Y = 38' in m
assert 'NICHT KONFIGURIERT' in l and 'local REACTORS_PER_PAGE = 16' in l
assert 'local button_w = 6' in r and '"EDIT", "LIMITED", 1' in r
assert 'DISABLED_FIXED_SCALE_1' in h
assert v.count('apply_valve(true, true)') == 1 and 'apply_valve(false' not in v
for text in (l,r,m):
  for bad in ('set_logistics_enabled(','begin_transaction(','record_export(','require("nodes.fuel.logistics_router")','require("nodes.fuel.redstone_router")'):
    assert bad not in text,bad
print('package_contract_test.py: ok')
