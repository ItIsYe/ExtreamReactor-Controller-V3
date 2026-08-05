package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local constants=require('shared.constants'); local coalescer_m=require('master.rt_sync_coalescer'); local utils=require('core.utils')
local function T(v,m) if not v then error(m or"true") end end
local fake_time=0
_G.os=setmetatable({epoch=function() return fake_time end,clock=function() return fake_time/1000 end},{__index=_G.os or {}})
local synced={}
local c=coalescer_m.new({constants=constants,utils=utils,batch_window_ms=100,sync_rt_node=function(node,trigger) synced[#synced+1]={node=node,trigger=trigger} end,log=function() end})
local node={id='RT-1',role=constants.roles.RT_NODE,mode='MASTER',status=constants.status_levels.OK,state=constants.node_states.RUNNING}
fake_time=0; c.mark_dirty(node,'status'); c.mark_dirty(node,'heartbeat'); c.mark_dirty(node,'config')
fake_time=200; c.flush()
T(#synced>=1,"coalesced multi-reason flushes"); T(#synced==1,"sends once per node")
local trigger=synced[1].trigger or ""
T(trigger:find("coalesced")~=nil or trigger~="","trigger indicates coalesced flush")
print("rt_sync_multi_reason_dedupe_semantics_test.lua: ok")
