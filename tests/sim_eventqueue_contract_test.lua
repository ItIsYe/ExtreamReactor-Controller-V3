local eq=dofile("tests/sim/cc/event_queue.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end
local q=eq.new()
q:push("timer",42);local ev,id=q:pull();A(ev,"timer");A(id,42)
q:push("x",1);q:push("y",30);q:push("timer",7)
local e2,i2=q:pull("timer");A(e2,"timer","f");A(i2,7);A(q:size(),0,"e")
q:push("terminate");local o,_=pcall(function() q:pull() end);A(o,false,"term")
q:push("terminate");local r=q:pull_raw();A(r,"terminate","raw")
q:push("a");q:push("b");q:push("c");A(q:size(),3);T(not q:empty())
q:clear();T(q:empty())
print("sim_eventqueue_contract_test.lua: ok")
