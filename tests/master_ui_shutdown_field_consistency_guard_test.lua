local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local producer=read('xreactor/master/runtime_ops_rt.lua'); local projection=read('xreactor/master/ui_controller.lua'); local view=read('xreactor/master/ui/rt_dashboard.lua')
for _,field in ipairs({'stage','outcome','final_reason','target_state','requested_at','completed_at'}) do assert(producer:find('workflow.'..field,1,true),'producer missing workflow.'..field) end
for _,field in ipairs({'shutdown_stage','shutdown_outcome','shutdown_reason','shutdown_target_state','shutdown_requested_at','shutdown_completed_at'}) do assert(projection:find(field,1,true),'UI projection missing '..field) end
assert(view:find('shutdown_verdict',1,true) and view:find('QUEUE / SD',1,true),'RT dashboard must surface shutdown workflow verdict')
print('master_ui_shutdown_field_consistency_guard_test.lua: ok')
