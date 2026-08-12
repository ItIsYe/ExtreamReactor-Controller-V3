local k=dofile("tests/sim/cc/kernel.lua")
local eq=dofile("tests/sim/cc/event_queue.lua")
local sm=dofile("tests/sim/cc/scheduler.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end
k.reset(0)
local ra,rb=nil,nil
local sch=sm.new(k,eq)
sch:add(function() ra=coroutine.yield() end,"a")
sch:add(function() rb=coroutine.yield() end,"b")
for _,e in ipairs(sch._cos) do coroutine.resume(e.co) end
sch:broadcast("timer",99);sch:step()
A(ra,"timer","co_a");A(rb,"timer","co_b")
k.reset(0);local sh=eq.new();local done={}
local o,e=pcall(sm.wait_for_any,k,eq,
  {function() done[#done+1]="fast" end,
   function() coroutine.yield();done[#done+1]="slow" end},sh,100)
T(o,"wfa: "..tostring(e));A(done[1],"fast","fast")
k.reset(0);local sh2=eq.new()
local o2,e2=pcall(sm.wait_for_any,k,eq,{function() error("deliberate") end},sh2,10)
A(o2,false,"prop");T(tostring(e2):find("deliberate")~=nil,"msg:"..tostring(e2))
print("sim_scheduler_contract_test.lua: ok")
