package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local function reset() package.loaded["core.utils"]=nil;package.loaded["adapters.reactor"]=nil end
local function T(v,m) if not v then error(m or"assert") end end
reset();local calls={}
_G.peripheral={isPresent=function() return true end,
  getMethods=function() return {"setAllControlRodLevels","getControlRodsLevels","getActive",
    "getCasingTemperature","getFuelAmount","getWasteAmount","getFuelCapacity","getWasteCapacity"} end,
  getType=function() return "BigReactors-Reactor" end,
  call=function(name,method,...)
    calls[method]=(calls[method] or 0)+1
    if method=="getControlRodsLevels" then return {10,20} end; return true
  end}
local r1=require("adapters.reactor"); r1.apply_rod_level("reactor_0",75,"TEST")
T(calls["setAllControlRodLevels"]~=nil,"setAllControlRodLevels preferred")
reset();calls={}
_G.peripheral={isPresent=function() return true end,
  getMethods=function() return {"setControlRodsLevels","getControlRodsLevels","getActive",
    "getCasingTemperature","getFuelAmount","getWasteAmount","getFuelCapacity","getWasteCapacity"} end,
  getType=function() return "BigReactors-Reactor" end,
  call=function(name,method,...)
    calls[method]=(calls[method] or 0)+1
    if method=="getControlRodsLevels" then return {10,20,30,40}
    elseif method=="setControlRodsLevels" then
      local levels=({...})[1]; T(type(levels)=="table","table"); T(levels[1]~=nil,"1-based"); return true
    end; return true
  end}
local r2=require("adapters.reactor"); r2.apply_rod_level("reactor_0",50,"TEST")
T(calls["setControlRodsLevels"]~=nil,"setControlRodsLevels fallback 1-based")
reset()
_G.peripheral={isPresent=function() return true end,
  getMethods=function() return {"getControlRodsLevels","getActive","getCasingTemperature",
    "getFuelAmount","getWasteAmount","getFuelCapacity","getWasteCapacity"} end,
  getType=function() return "BigReactors-Reactor" end,
  call=function(name,method,...) if method=="getControlRodsLevels" then return {25,25,25,25} end; return true end}
local r3=require("adapters.reactor"); local level,err=r3.read_control_rods("reactor_0","TEST")
T(level~=nil or err~=nil,"read_control_rods must return")
print("reactor_control_rods_regression_test.lua: ok")
