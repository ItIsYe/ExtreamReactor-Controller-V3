package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local constants=require('shared.constants'); local rt_sync=require('master.rt_sync')
local function T(v,m) if not v then error(m or"true") end end
local function mk(id) return {id=id,role=constants.roles.RT_NODE,mode='MASTER',status=constants.status_levels.OK,state=constants.node_states.RUNNING,output=0,actual_output=0,capacity_ready=true,capacity_max=3000} end
local nodes={['RT-1']=mk('RT-1'),['RT-2']=mk('RT-2'),['RT-3']=mk('RT-3')}
local plan=rt_sync.build_node_setpoint_plan({config={rt_setpoints={target_rpm=900,steam_target=4000,enable_reactors=true,enable_turbines=true}},nodes=nodes,power_target=3000,rt_global_off=false})
T(plan~=nil,"plan not nil"); T(type(plan.nodes)=="table","plan.nodes table")
T(#plan.nodes>=1,"at least one node"); T(plan.controllable_count>=1,"controllable_count>=1")
print("rt_sync_demand_sequencing_test.lua: ok")
