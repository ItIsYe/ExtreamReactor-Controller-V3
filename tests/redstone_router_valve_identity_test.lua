package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local tx={}
local modem={isWireless=function() return true end,open=function() end,transmit=function(_,_,m) tx[#tx+1]=m end}
_G.peripheral={find=function(k,f) if k=='modem' and (not f or f('right',modem)) then return modem end end,isPresent=function() return false end,wrap=function() return nil end}
_G.redstone={setOutput=function() end}
package.loaded['nodes.fuel.redstone_router']=nil
local lib=require('nodes.fuel.redstone_router')
local protocol=require('core.protocol'); local SECRET='router-test-secret-1234'
-- Production callers inject the already-resolved runtime node_id explicitly.
local router=lib.new({node_id='node-77',config={node_id='ROLE-DEFAULT',auth_secret=SECRET,logistics={redstone_tree={{reactor='R1',path={{side='left',integrator='VALVE-1'}}}}}},comms={get_peers=function() return {['VALVE-1']={down=false}} end},log=function() end,warn_once=function() end})
router:refresh(); assert(#tx>=1); local sent=tx[#tx]; assert(sent.src=='node-77'); assert(sent.command_id:match('^node%-77%-'))
local key='VALVE-1|left'; local pending=assert(router._state.pending_valve_acks[key]); assert(pending.src=='node-77')
local function ack(src,dst)
  local m={type='VALVE_ACK',command_id=pending.command_id,src=src,dst=dst,applied=true,high=true,ts=os.epoch('utc')}
  m.auth={algorithm='HMAC-SHA256',mac=assert(protocol.sign_value(protocol.valve_auth_value(m),SECRET))}; router:handle_valve_ack(m)
end
ack('EVIL','node-77'); assert(router._state.pending_valve_acks[key])
ack('VALVE-1','wrong'); assert(router._state.pending_valve_acks[key])
ack('VALVE-1','node-77'); assert(router._state.pending_valve_acks[key]==nil)
local ok,cid=router:_set_valve({side='left',integrator='VALVE-1'},false); assert(ok and cid); local retry=assert(router._state.pending_valve_acks[key]); retry.sent_ts=-4000; router:check_pending_acks(); local resent=tx[#tx]; assert(resent.command_id==cid and resent.src=='node-77')
print('redstone_router_valve_identity_test.lua: ok')
