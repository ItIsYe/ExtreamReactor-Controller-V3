local k=dofile("tests/sim/cc/kernel.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end
k.reset(42);A(k.now_ticks(),0,"t0");A(k.now_s(),0,"s0")
k.tick();k.tick();k.tick();A(k.now_ticks(),3,"3t")
k.reset(0);k.advance_s(0.1);A(k.now_ticks(),2,"2t")
k.reset(0);k.advance_s(0.11);A(k.now_ticks(),3,"3t")
k.reset(0);k.advance(10);A(k.epoch_ms(),500,"500ms")
k.reset(123);local r1=math.random();k.reset(123);local r2=math.random();A(r1,r2,"repro")
local old=k.MAX_TICKS;k.MAX_TICKS=5;k.reset(0);k.advance(5)
A(k.now_ticks(),5,"at limit")
local o,e=pcall(k.check_limit);A(o,false,"limit: "..tostring(e))
T(tostring(e):find("Tick")~=nil,"Tick in: "..tostring(e))
k.MAX_TICKS=old
print("sim_kernel_contract_test.lua: ok")
