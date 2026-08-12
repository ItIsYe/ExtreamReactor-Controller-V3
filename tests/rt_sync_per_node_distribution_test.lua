package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local constants=require('shared.constants')
local rt_sync=require('master.rt_sync')
local function assert_eq(a,e,m) if a~=e then error((m or'eq')..': exp='..tostring(e)..' act='..tostring(a)) end end
local function assert_true(v,m) if not v then error(m or'true') end end
local function mk(id,state,out,cap)
  return {id=id,role=constants.roles.RT_NODE,mode='MASTER',
          status=constants.status_levels.OK,state=state,
          output=out or 0,actual_output=out or 0,
          capacity_ready=true,capacity_max=cap or out or 3000}
end

local plan=rt_sync.build_node_setpoint_plan({
  config={rt_setpoints={target_rpm=900,steam_target=4000,enable_reactors=true,enable_turbines=true}},
  nodes={
    ['RT-1']=mk('RT-1',constants.node_states.RUNNING,2000,3000),
    ['RT-2']=mk('RT-2',constants.node_states.RUNNING,1000,3000),
    ['RT-3']={id='RT-3',role=constants.roles.RT_NODE,mode='SAFE',
              status=constants.status_levels.WARNING,state=constants.node_states.SAFE,
              output=0,actual_output=0,capacity_ready=true,capacity_max=3000},
  },
  power_target=6000,rt_global_off=false
})
assert_eq(plan.controllable_count,2,'expected two controllable nodes')
local sp={}
for _,e in ipairs(plan.nodes) do sp[e.id]=e.setpoints end
assert_true(sp['RT-1']~=nil,'RT-1 must have setpoints')
assert_true(sp['RT-2']~=nil,'RT-2 must have setpoints')
assert_true(sp['RT-3']~=nil,'RT-3 must have setpoints')
assert_true((sp['RT-3'].power_target_percent or 0)==0,'safe-mode node must not receive active setpoints')
assert_eq(sp['RT-1'].power_target_percent,sp['RT-2'].power_target_percent,
  'active nodes get equal pct in proportional distribution')
print("rt_sync_per_node_distribution_test.lua: ok")
