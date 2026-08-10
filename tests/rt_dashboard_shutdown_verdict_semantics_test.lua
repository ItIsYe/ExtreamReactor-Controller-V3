local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local ui=read('xreactor/master/ui/rt_dashboard.lua'); local proj=read('xreactor/master/ui_controller.lua')
for _,token in ipairs({'SD:OK','SD:FAIL','SD:CANCELLED','shutdown_verdict(rt)','QUEUE / SD'}) do assert(ui:find(token,1,true),'dashboard missing semantic shutdown verdict '..token) end
for _,token in ipairs({'shutdown_stage','shutdown_outcome','shutdown_reason'}) do assert(proj:find(token,1,true),'UI model missing shutdown field '..token) end
assert(ui:find('stage == "COMPLETED"',1,true),'COMPLETED stage must render as success')
assert(ui:find('stage == "FAILED"',1,true),'FAILED stage must render as failure')
assert(ui:find('stage == "CANCELLED_DEMAND_RECOVERED"',1,true),'cancelled demand recovery must remain distinct from failure')
print('rt_dashboard_shutdown_verdict_semantics_test.lua: ok')
