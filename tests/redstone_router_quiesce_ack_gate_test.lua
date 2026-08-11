package.path = table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path}, ';')
local clock=1000000; os.epoch=function() return clock end
local rr=require('nodes.fuel.redstone_router')
local protocol=require('core.protocol'); local SECRET='router-test-secret-1234'
local sent={}
local modem={isWireless=function() return true end,open=function() end,transmit=function(_,_,m) sent[#sent+1]=m; return true end}
_G.peripheral={find=function(k) if k=='modem' then return modem end end,isPresent=function() return false end,wrap=function() return nil end}
local function make()
  local r=rr.new({config={auth_secret=SECRET,logistics={redstone_tree={
    {side='top',integrator='V1',reactor='R1'},{side='bottom',integrator='V2',reactor='R2'} }}},
    comms={get_peers=function() return {V1={down=false,stale=false},V2={down=false,stale=false}} end},log=function() end,warn_once=function() end})
  r:refresh(); return r
end
local function ack(r,id,side)
  local key=id..'|'..side; local e=assert(r._state.pending_valve_acks[key], 'pending '..key)
  local m={type='VALVE_ACK',command_id=e.command_id,src=e.dst,dst=e.src,applied=true,high=true,ts=clock}
  m.auth={algorithm='HMAC-SHA256',mac=assert(protocol.sign_value(protocol.valve_auth_value(m),SECRET))}; r:handle_valve_ack(m)
end
local r=make()
assert(r:begin_quiesce('UPDATE_QUIESCE') == false, 'wireless quiesce cannot be confirmed before ACKs')
assert(r:poll_quiesce(clock) == false)
ack(r,'V1','top'); assert(r:poll_quiesce(clock) == false, 'one missing valve ACK must keep runtime quiescing')
ack(r,'V2','bottom'); assert(r:poll_quiesce(clock) == true, 'all current BLOCKED ACKs should confirm quiesce')
assert(r._state.quiesce.state == 'CONFIRMED')

local direct=rr.new({config={logistics={redstone_tree={}}},log=function() end,warn_once=function() end})
direct:refresh(); assert(direct:begin_quiesce('UPDATE_QUIESCE') == true, 'no configured routing has no valve ACK obligation')
print('redstone_router_quiesce_ack_gate_test.lua: ok')
