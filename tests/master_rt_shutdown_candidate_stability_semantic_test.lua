package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local M=require('master.rt_sync_coalescer')
local function T(v,m) if not v then error(m or"true") end end
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local wf={}; local now=1000
local r1=M.advance_shutdown_candidate({workflow=wf,now=now,is_candidate=true,stability_ms=1500})
A(r1.action,"debounce_stability","fresh → debounce"); T(r1.remaining_ms>0,"remaining>0")
local r2=M.advance_shutdown_candidate({workflow=wf,now=now+500,is_candidate=true,stability_ms=1500})
A(r2.action,"debounce_stability","still debouncing")
local r3=M.advance_shutdown_candidate({workflow=wf,now=now+2000,is_candidate=true,stability_ms=1500})
A(r3.action,"start_requested","after stability_ms")
wf.requested_at=now+2000
local r4=M.advance_shutdown_candidate({workflow=wf,now=now+2100,is_candidate=true,stability_ms=1500})
A(r4.action,"candidate_active","with requested_at")
wf.cancelled_at=now+2200
local r5=M.advance_shutdown_candidate({workflow=wf,now=now+2300,is_candidate=true,stability_ms=1500,restart_cooldown_ms=60000})
A(r5.action,"debounce_cooldown","after cancel")
print("master_rt_shutdown_candidate_stability_semantic_test.lua: ok")
