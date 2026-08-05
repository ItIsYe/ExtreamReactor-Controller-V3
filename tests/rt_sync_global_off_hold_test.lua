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

local sends=0
local comms={send_command=function() sends=sends+1 end}
local node=mk('node-rt',constants.node_states.RUNNING,2000,3000)
rt_sync.sync_rt_node({
  config={rt_setpoints={target_rpm=900,enable_reactors=true,enable_turbines=true}},
  comms=comms,nodes={['node-rt']=node},
  power_target=5500,rt_global_off=true,log=function() end
},node)
assert_eq(sends,1,'expected one setpoint command when syncing rt node, got '..sends)
assert_true(node.last_setpoints~=nil,'node must have last_setpoints after sync')
assert_true((node.last_setpoints.power_target_percent or 0)==0,'global off must set pct to 0')
print("rt_sync_global_off_hold_test.lua: ok")
