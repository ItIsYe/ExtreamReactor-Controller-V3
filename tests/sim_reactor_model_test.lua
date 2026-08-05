local M=dofile("tests/sim/models/reactor.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end
local r=M.new({initial_fuel=4000,rod_level=0,readback_lag=1})
T(r.getActive(),"active"); A(r.getFuelCapacity(),4000,"cap")
T(r.getCasingTemperature()>=20,"init temp")
local r2=M.new({active=false,casing_temp=500}); r2.tick();r2.tick();r2.tick()
T(r2.getCasingTemperature()<500,"cooling")
local r3=M.new({rod_level=0,initial_fuel=1000}); local t0=r3.getCasingTemperature(); local f0=r3.getFuelAmount()
for _=1,20 do r3.tick() end
T(r3.getCasingTemperature()>t0,"temp rises"); T(r3.getFuelAmount()<f0,"fuel consumed"); T(r3.getWasteAmount()>0,"waste")
local r4=M.new({rod_level=100,initial_fuel=4000}); local tb=r4.getCasingTemperature()
for _=1,10 do r4.tick() end; T(r4.getCasingTemperature()<=tb+5,"full rods")
local r5=M.new({rod_level=0}); r5.setAllControlRodLevels(50); A(r5.getControlRods()[1].level,50,"setAll")
r5.setControlRod(0,75); A(r5.getControlRodLevel(0),75,"setRod")
r5.setActive(false); A(r5.getActive(),false,"inactive"); r5.setActive(true); A(r5.getActive(),true,"active")
print("sim_reactor_model_test.lua: ok")
