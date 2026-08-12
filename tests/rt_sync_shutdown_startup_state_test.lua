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
    ['RT-1']=mk('RT-1',constants.node_states.RUNNING,3200,3200),
    ['RT-2']=mk('RT-2',constants.node_states.RUNNING,1500,1500),
    ['RT-3']=mk('RT-3',constants.node_states.OFF,0,3000),
  },
  power_target=2500,rt_global_off=false
})
local by_id={}
for _,e in ipairs(plan.nodes) do by_id[e.id]=e.setpoints end
assert_eq(by_id['RT-1'].assignment_state,'active','RT-1 should remain active for low demand')
assert_eq(by_id['RT-2'].assignment_state,'shed','RT-2 should be first shed candidate')
assert_true((by_id['RT-2'].power_target_percent or 0)==0,'shed node must receive zero power target')
assert_true(by_id['RT-3'].assignment_state=='standby' or by_id['RT-3'].assignment_state=='startup',
  'startup pending node should wait in standby or startup')
print("rt_sync_shutdown_startup_state_test.lua: ok")
