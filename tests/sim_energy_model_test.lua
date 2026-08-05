local M=dofile("tests/sim/models/energy.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end
local function near(a,e,tol,m) if math.abs(a-e)>tol then error((m or"near")..": exp~"..e.." act="..a) end end
local es=M.new({capacity=1000000,stored=0,max_input=100000,max_output=100000})
A(es.getEnergyStored(),0,"empty"); A(es.getMaxEnergyStored(),1000000,"cap")
es.tick(50000,0); A(es.getEnergyStored(),50000,"inp"); A(es.getLastTickInput(),50000,"li"); A(es.getLastTickOutput(),0,"lo")
es.tick(0,20000); A(es.getEnergyStored(),30000,"out"); A(es.getLastTickOutput(),20000,"lo2")
while es.getEnergyStored()<1000000 do es.tick(100000,0) end
A(es.getEnergyStored(),1000000,"capped")
local es2=M.new({capacity=1000000,stored=100}); es2.tick(0,50000); A(es2.getEnergyStored(),0,"floor 0")
local es3=M.new({capacity=1000000,stored=0,max_input=1000}); es3.tick(50000,0)
A(es3.getEnergyStored(),1000,"max_inp"); A(es3.getLastTickInput(),1000,"li3")
local es4=M.new({capacity=1000,stored=500}); near(es4.getEnergyFilledPercentage(),50,0.1,"50%")
local bl=es4.getConnectedEnergyBlocks(); T(#bl>=1,"blocks"); T(bl[1].max>0,"max")
local tv=es4.getTopologyVersion(); es4.invalidateTopology(); T(es4.getTopologyVersion()>tv,"topo")
print("sim_energy_model_test.lua: ok")
