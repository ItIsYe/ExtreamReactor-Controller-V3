package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
-- Regression: reactors exposing ONLY the indexed setControlRodLevel/
-- getControlRodLevel pair (no bulk getControlRodsLevels/getControlRodLevels/
-- getControlRods) must still get a working rod write. count_rods() cannot
-- resolve a count for such peripherals and used to make apply_rod_level()
-- bail out entirely with "unable to resolve rod count for indexed setter"
-- instead of defaulting to a single rod like it did before the clean
-- recovery audit.
local function reset() package.loaded["core.utils"]=nil;package.loaded["adapters.reactor"]=nil end
local function T(v,m) if not v then error(m or"assert") end end

-- Case 1: single indexed rod, index 0 works directly.
reset()
local calls={}
_G.peripheral={isPresent=function() return true end,
  getMethods=function() return {"setControlRodLevel","getControlRodLevel","getActive",
    "getCasingTemperature","getFuelAmount","getWasteAmount","getFuelCapacity","getWasteCapacity"} end,
  getType=function() return "BigReactors-Reactor" end,
  call=function(name,method,...)
    calls[method]=(calls[method] or 0)+1
    if method=="setControlRodLevel" then
      local index=({...})[1]
      T(index==0,"expected first attempt at index 0, got "..tostring(index))
      return true
    end
    return true
  end}
local r1=require("adapters.reactor")
local ok1,err1=r1.apply_rod_level("reactor_0",75,"TEST")
T(ok1==true,"indexed-only rod write must succeed via rod_count fallback: "..tostring(err1))
T(calls["setControlRodLevel"]==1,"exactly one write expected for single rod")

-- Case 2: single indexed rod, but the peripheral is 1-indexed (index 0
-- errors, index 1 succeeds) -- must retry before giving up.
reset()
calls={}
_G.peripheral={isPresent=function() return true end,
  getMethods=function() return {"setControlRodLevel","getControlRodLevel","getActive",
    "getCasingTemperature","getFuelAmount","getWasteAmount","getFuelCapacity","getWasteCapacity"} end,
  getType=function() return "BigReactors-Reactor" end,
  call=function(name,method,...)
    if method=="setControlRodLevel" then
      local index=({...})[1]
      calls[#calls+1]=index
      if index==0 then return nil,"bad argument #1: index out of range" end
      return true
    end
    return true
  end}
local r2=require("adapters.reactor")
local ok2,err2=r2.apply_rod_level("reactor_0",60,"TEST")
T(ok2==true,"1-indexed rod write must succeed via retry fallback: "..tostring(err2))
T(#calls==2 and calls[1]==0 and calls[2]==1,"expected retry at index 1 after index 0 failed")

print("reactor_rod_indexed_setter_single_rod_fallback_test.lua: ok")
