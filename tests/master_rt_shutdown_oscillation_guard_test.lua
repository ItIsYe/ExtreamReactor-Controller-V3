local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local ops=read('xreactor/master/runtime_ops_rt.lua')
local coalescer=read('xreactor/master/rt_sync_coalescer.lua')
for _,t in ipairs({'shutdown_candidate_stability_ms','shutdown_restart_cooldown_ms','advance_shutdown_candidate','CANCELLED_DEMAND_RECOVERED'}) do
  assert((ops..coalescer):find(t,1,true),'missing shutdown anti-oscillation contract '..t)
end
assert(coalescer:find('workflow.cancelled_at',1,true),'cancel timestamp required for restart cooldown')
assert(coalescer:find('debounce_stability',1,true) and coalescer:find('debounce_cooldown',1,true),'both stability and cooldown gates required')
print('master_rt_shutdown_oscillation_guard_test.lua: ok')
