package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local handler=require('nodes.fuel.command_handler')
local devices={}
local result
local sch={
  parse_node_command=function() return {target='SET_RESERVE',value=4200} end,
  finish_with_result=function(_,r) result=r; return r end,
  finish=function() return {ok=true} end,
  reject_unsupported=function() return {ok=false} end,
}
local calls=0
local out=handler.handle({}, {support_command_handler=sch,constants={command_targets={SET_RESERVE='SET_RESERVE',FUEL_STATUS='FUEL_STATUS',MODE='MODE'},node_states={MANUAL='MANUAL'}},devices=devices,
  protocol={},comms={},utils={log=function() end},set_reserve=function(v) calls=calls+1; assert(v==4200); return {ok=true,persisted=false,persistence_error='disk full'} end,on_fuel_status=function() end})
assert(calls==1 and out.persisted==false and out.persistence_error=='disk full','SET_RESERVE ACK must preserve persistence failure')
print('fuel_reserve_persistence_ack_test.lua: ok')
