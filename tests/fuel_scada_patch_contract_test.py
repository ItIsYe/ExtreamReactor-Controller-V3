from pathlib import Path
R=Path(__file__).resolve().parents[1]
l=(R/'xreactor/nodes/fuel/scada_layout.lua').read_text(encoding='utf-8')
r=(R/'xreactor/nodes/fuel/router_scada.lua').read_text(encoding='utf-8')
m=(R/'xreactor/nodes/fuel/monitor_scada.lua').read_text(encoding='utf-8')
for text,name in ((l,'layout'),(r,'router'),(m,'monitor')):
    assert 'TARGET_W = 82' in text and 'TARGET_H = 40' in text,name
    for bad in ('require("nodes.fuel.logistics_router")','require("nodes.fuel.redstone_router")','require("services.comms_service")','set_logistics_enabled(','_do_save(','begin_transaction(','record_export('):
        assert bad not in text,(name,bad)
assert 'TARGET_SCALE = 1.0' in m and 'SUPPORTED_SCALES = { 1.0 }' in m
for mode in ('_render_list','_render_edit','_render_learn','_render_chest_pick','_render_path'):
    assert f'router.{mode} = function' in r,mode
print('fuel_scada_patch_contract_test.py: ok')
