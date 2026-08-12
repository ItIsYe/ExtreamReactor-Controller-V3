package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local constants=require('shared.constants'); local rt_sync=require('master.rt_sync')
local function T(v,m) if not v then error(m or"true") end end
local function mk(id,st) return {id=id,role=constants.roles.RT_NODE,mode='MASTER',
  status=constants.status_levels.OK,state=st,output=0,actual_output=0,capacity_ready=true,capacity_max=3000} end
local nodes={['RT-1']=mk('RT-1',constants.node_states.RUNNING),['RT-2']=mk('RT-2',constants.node_states.OFF)}
nodes['RT-2'].status=constants.status_levels.ERROR
local plan=rt_sync.build_node_setpoint_plan({config={rt_setpoints={target_rpm=900,steam_target=4000,enable_reactors=true,enable_turbines=true}},nodes=nodes,power_target=3000,rt_global_off=false})
local rt2=nil; for _,e in ipairs(plan.nodes) do if e.id=='RT-2' then rt2=e end end
T(rt2~=nil,"RT-2 in plan")
nodes['RT-2'].status=constants.status_levels.OK; nodes['RT-2'].state=constants.node_states.RUNNING; nodes['RT-2'].capacity_ready=true
local plan2=rt_sync.build_node_setpoint_plan({config={rt_setpoints={target_rpm=900,steam_target=4000,enable_reactors=true,enable_turbines=true}},nodes=nodes,power_target=6000,rt_global_off=false})
T(plan2.controllable_count>=1,"recovered node controllable")
print("master_heartbeat_recovery_from_down_test.lua: ok")
