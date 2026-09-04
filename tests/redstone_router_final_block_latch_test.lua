package.path = table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path}, ';')
local clock=2000000; os.epoch=function() return clock end
local rr=require('nodes.fuel.redstone_router')
local modem={isWireless=function() return true end,open=function() end,transmit=function() return true end}
_G.peripheral={find=function(k) if k=='modem' then return modem end end,isPresent=function() return false end,wrap=function() return nil end}
local peers={V1={down=false,stale=false},V2={down=false,stale=false}}
local r=rr.new({config={logistics={redstone_tree={{side='top',integrator='V1',reactor='R1'},{side='bottom',integrator='V2',reactor='R2'}}}},
  comms={get_peers=function() return peers end},log=function() end,warn_once=function() end})
r:refresh()
local function ack(id,side,applied,high)
  local key=id..'|'..side; local e=assert(r._state.pending_valve_acks[key], 'pending '..key)
  r:handle_valve_ack({type='VALVE_ACK',command_id=e.command_id,src=e.dst,dst=e.src,applied=applied~=false,high=high==nil and e.high or high})
end
local completed
local ok,reason,txid=r:begin_transaction('R1',function() return true end,100,{on_complete=function(i) completed=i end})
assert(ok and txid, reason)
ack('V1','top',true,true); ack('V2','bottom',true,true); r:tick(clock)
ack('V1','top',true,false); r:tick(clock); clock=clock+500; r:tick(clock)
assert(r:get_active_transaction().phase=='HOLDING')
clock=clock+200; r:tick(clock); assert(r:get_active_transaction().phase=='FINAL_BLOCK')
ack('V1','top',false,true); ack('V2','bottom',true,true); r:tick(clock)
assert(r:get_active_transaction()==nil, 'failed final ACK ends active tx but must latch safety')
assert(r:get_safety_latch() and r:get_safety_latch().state=='FINAL_BLOCK_UNCONFIRMED')
assert(completed and completed.state=='FINAL_BLOCK_UNCONFIRMED')
local ok2,reason2=r:begin_transaction('R1',function() end,100)
assert(not ok2 and reason2=='safety_latched', 'new delivery must be blocked by unresolved final safety fault')
ack('V1','top',true,true); ack('V2','bottom',true,true); r:tick(clock)
assert(r:get_safety_latch()==nil, 'fresh all-BLOCKED confirmation should clear latch')
local ok3=r:begin_transaction('R1',function() end,100)
assert(ok3, 'new delivery may start only after latch clears')
print('redstone_router_final_block_latch_test.lua: ok')
