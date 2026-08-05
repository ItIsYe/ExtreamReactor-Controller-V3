local eq_cls=dofile("tests/sim/cc/event_queue.lua")
local per_m=dofile("tests/sim/cc/peripheral.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end
local eq=eq_cls.new(); local reg=per_m.new(eq)
reg.attach("reactor_0","BigReactors-Reactor",{
  getActive=function() return true end,
  getCasingTemperature=function() return 400.0 end,
  setActive=function() end, getControlRodLevels=function() return {10,20,30} end,
})
T(reg.isPresent("reactor_0"),"present"); A(reg.getType("reactor_0"),"BigReactors-Reactor","type")
T(not reg.isPresent("missing"),"not present")
local ev,name=eq:pull("peripheral"); A(ev,"peripheral","ev"); A(name,"reactor_0","name")
local methods=reg.getMethods("reactor_0"); T(#methods>=3,"methods")
local has=false; for _,m in ipairs(methods) do if m=="getActive" then has=true end end; T(has,"getActive")
A(reg.call("reactor_0","getActive"),true,"call"); T(reg.call("reactor_0","getCasingTemperature")>0,"temp")
local ok,_=pcall(reg.call,"missing","getActive"); A(ok,false,"call missing")
local ok2,_=pcall(reg.call,"reactor_0","nope"); A(ok2,false,"call nope")
local p=reg.wrap("reactor_0"); T(p~=nil,"wrap"); A(p.getActive(),true,"wrap.getActive")
T(reg.wrap("missing")==nil,"wrap nil")
reg.attach("reactor_1","BigReactors-Reactor",{getActive=function() return false end})
reg.attach("modem_0","modem",{open=function() end})
local r1,r2=reg.find("BigReactors-Reactor"); T(r1~=nil,"find r1"); T(r2~=nil,"find r2")
reg.detach("reactor_1"); T(not reg.isPresent("reactor_1"),"detached")
local dev,dn=eq:pull("peripheral_detach"); A(dev,"peripheral_detach","dev"); A(dn,"reactor_1","dn")
T(#reg.getNames()>=2,"getNames")
print("sim_peripheral_contract_test.lua: ok")
