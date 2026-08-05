local M={}
local D={base_fuel_rate=1,max_heat=2000,cooling_rate=0.5,thermal_mass=100,
  fuel_capacity=4000,waste_capacity=4000,initial_fuel=4000,num_rods=4,readback_lag=1}
function M.new(opts)
  opts=opts or {}; local cfg={}
  for k,v in pairs(D) do cfg[k]=opts[k]~=nil and opts[k] or v end
  local s={active=opts.active~=false,rod_levels={},fuel=cfg.initial_fuel,waste=0,
    casing_temp=opts.casing_temp or 20,
    _rb={casing_temp=opts.casing_temp or 20,fuel=cfg.initial_fuel,waste=0}}
  for i=1,cfg.num_rods do s.rod_levels[i]=opts.rod_level or 0 end
  local function avg() local x=0; for _,r in ipairs(s.rod_levels) do x=x+r end; return x/#s.rod_levels end
  local function tick()
    if not s.active then s.casing_temp=math.max(20,s.casing_temp-cfg.cooling_rate)
    else
      local eff=1-avg()/100; local fu=cfg.base_fuel_rate*eff
      s.fuel=math.max(0,s.fuel-fu); s.waste=math.min(cfg.waste_capacity,s.waste+fu*0.8)
      local dT=(fu*50-cfg.cooling_rate)/cfg.thermal_mass
      s.casing_temp=math.max(20,math.min(cfg.max_heat,s.casing_temp+dT))
    end
    local lag=math.max(1,cfg.readback_lag)
    s._rb.casing_temp=s._rb.casing_temp+(s.casing_temp-s._rb.casing_temp)/lag
    s._rb.fuel=s._rb.fuel+(s.fuel-s._rb.fuel)/lag
    s._rb.waste=s._rb.waste+(s.waste-s._rb.waste)/lag
  end
  local api={}; api.tick=tick
  function api.getActive() return s.active end
  function api.setActive(v) s.active=v==true end
  function api.getCasingTemperature() return s._rb.casing_temp end
  function api.getFuelAmount() return s._rb.fuel end
  function api.getWasteAmount() return s._rb.waste end
  function api.getFuelCapacity() return cfg.fuel_capacity end
  function api.getWasteCapacity() return cfg.waste_capacity end
  function api.getControlRods()
    local r={}; for i,l in ipairs(s.rod_levels) do r[i]={index=i-1,level=l,name="CR"..i} end; return r
  end
  function api.getControlRodLevel(i) return s.rod_levels[i+1] or 0 end
  function api.setControlRod(i,l) s.rod_levels[i+1]=math.max(0,math.min(100,l)) end
  function api.setAllControlRodLevels(l) for i=1,#s.rod_levels do s.rod_levels[i]=math.max(0,math.min(100,l)) end end
  function api.setControlRodsLevels(ls)
    if type(ls)=="table" then for i,l in pairs(ls) do
      local idx=type(i)=="number" and i or tonumber(i)
      if idx then s.rod_levels[idx+1]=math.max(0,math.min(100,l)) end
    end end
  end
  function api._state() return s end; function api._cfg() return cfg end; function api._avg_rod() return avg() end
  return api
end
return M
