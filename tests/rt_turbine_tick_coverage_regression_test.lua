-- INDUCTOR_UPDATE_FAILED_NONFATAL/SET_ACTIVE_FAILED_NONFATAL were reason
-- tags for a per-tick diagnostic bookkeeping cluster (eval_total/eval_
-- skipped/skip_reasons/track_skip()) that computed counts and then threw
-- them away -- fed into an `if eval_decision > 0 then end` block with no
-- body. Removed as dead code; the underlying non-fatal-error branches
-- themselves (ctx.warn_once("turbine_inductor:"...)/("turbine_active:"...))
-- are unchanged, so the guard below now checks those directly instead of
-- the removed dead-code labels.
local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local s=read('xreactor/nodes/rt/turbine_control.lua')
for _,t in ipairs({'turbine_inductor:','turbine_active:','OVERSPEED_BRAKE_FLOW_ZERO','enforce_overspeed_brake_coil','for _, name in ipairs(ctx.config.turbines or {}) do'}) do assert(s:find(t,1,true),'turbine control missing coverage/safety contract '..t) end
assert(s:find('update_inductor_for_rpm',1,true) and s:find('update_turbine_flow_state',1,true),'every turbine tick must retain coil and flow decisions')
print('rt_turbine_tick_coverage_regression_test.lua: ok')
