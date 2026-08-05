package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local constants=require('shared.constants'); local rt_sync=require('master.rt_sync')
local function T(v,m) if not v then error(m or"true") end end
local sends=0; local comms={send_command=function() sends=sends+1 end}
local node={id='RT-1',role=constants.roles.RT_NODE,mode='MASTER',status=constants.status_levels.OK,state=constants.node_states.RUNNING,output=2000,actual_output=2000,capacity_ready=true,capacity_max=3000,last_ack={rod_level=50,rpm_target=900}}
rt_sync.sync_rt_node({comms=comms,config={rt_setpoints={target_rpm=900,steam_target=4000,enable_reactors=true,enable_turbines=true}},nodes={['RT-1']=node},power_target=2000,rt_global_off=false,trigger='ack_applied',log=function() end},node)
T(sends>=1,"sends even after ack_applied (no resend suppression)")
print("rt_sync_ack_applied_no_resend_semantics_test.lua: ok")
