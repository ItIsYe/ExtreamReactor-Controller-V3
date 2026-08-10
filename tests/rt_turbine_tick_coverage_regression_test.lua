local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local s=read('xreactor/nodes/rt/turbine_control.lua')
for _,t in ipairs({'INDUCTOR_UPDATE_FAILED_NONFATAL','SET_ACTIVE_FAILED_NONFATAL','OVERSPEED_BRAKE_FLOW_ZERO','enforce_overspeed_brake_coil','for _, name in ipairs(ctx.config.turbines or {}) do'}) do assert(s:find(t,1,true),'turbine control missing coverage/safety contract '..t) end
assert(s:find('update_inductor_for_rpm',1,true) and s:find('update_turbine_flow_state',1,true),'every turbine tick must retain coil and flow decisions')
print('rt_turbine_tick_coverage_regression_test.lua: ok')
