package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local constants=require('shared.constants'); local rt_sync=require('master.rt_sync')
local function T(v,m) if not v then error(m or"true") end end
local sends=0; local comms={send_command=function() sends=sends+1 end}
local node={id='RT-1',role=constants.roles.RT_NODE,mode='MASTER',status=constants.status_levels.OK,state=constants.node_states.RUNNING,output=0,actual_output=0,capacity_ready=true,capacity_max=3000}
local ctx={comms=comms,config={rt_setpoints={target_rpm=900,steam_target=4000,enable_reactors=true,enable_turbines=true}},nodes={['RT-1']=node},power_target=0,rt_global_off=false,trigger='shutdown_ack',log=function() end}
rt_sync.sync_rt_node(ctx,node); local after_first=sends
rt_sync.sync_rt_node(ctx,node)
T(sends>after_first,"second sync sends (no shutdown-ack dedupe regression)")
print("rt_sync_ack_dedupe_regression_test.lua: ok")
