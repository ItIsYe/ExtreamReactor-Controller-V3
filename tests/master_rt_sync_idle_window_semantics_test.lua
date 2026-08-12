package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local constants=require('shared.constants'); local coalescer_m=require('master.rt_sync_coalescer'); local utils=require('core.utils')
local function T(v,m) if not v then error(m or"true") end end
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local fake_time=0
_G.os=setmetatable({epoch=function() return fake_time end,clock=function() return fake_time/1000 end},{__index=_G.os or {}})
local synced={}
local c=coalescer_m.new({constants=constants,utils=utils,batch_window_ms=100,sync_rt_node=function(node,trigger) synced[#synced+1]={node=node,trigger=trigger} end,log=function() end})
local node={id='RT-1',role=constants.roles.RT_NODE,mode='MASTER',status=constants.status_levels.OK,state=constants.node_states.RUNNING}
fake_time=0; c.mark_dirty(node,'status'); fake_time=50; c.flush()
A(#synced,0,"before window: no send"); fake_time=200; c.flush()
T(#synced>=1,"after window: send")
print("master_rt_sync_idle_window_semantics_test.lua: ok")
