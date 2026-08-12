local k=dofile("tests/sim/cc/kernel.lua")
local eq=dofile("tests/sim/cc/event_queue.lua")
local tm=dofile("tests/sim/cc/timers.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end
k.reset(0);local q=eq.new();local t=tm.new(k)
local i1=t:start(0.1);local i2=t:start(0.05);T(i1~=i2,"uid")
local i3=t:start(0.01);A(t:count(),3,"3p")
k.advance(1);local f=t:fired(q);A(f,2,"2f");A(q:size(),2,"2ev")
local _,f1=q:pull("timer");local _,f2=q:pull("timer");T(f1<f2,"ord")
local i4=t:start(0.1);t:cancel(i4);k.advance(3);t:fired(q)
local _,f3=q:pull("timer");A(f3,i1,"i1");A(q:size(),0,"e")
local i5=t:start(0);k.advance(1);T(t:fired(q)>=1,"0s")
print("sim_timers_contract_test.lua: ok")
