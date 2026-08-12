local M={}
local D={target_rpm=900,max_rpm=2000,coil_engage_rpm=900,ramp_rate=5,
  flow_capacity=2000,coil_engaged=false,initial_rpm=0,initial_flow=0,
  readback_lag=1,energy_per_rpm=10}
function M.new(opts)
  opts=opts or {}; local cfg={}
  for k,v in pairs(D) do cfg[k]=opts[k]~=nil and opts[k] or v end
  local s={active=opts.active~=false,rpm=opts.initial_rpm or 0,
    flow_target=opts.initial_flow or 0,flow_actual=opts.initial_flow or 0,
    coil_engaged=cfg.coil_engaged,_rb={rpm=opts.initial_rpm or 0,flow=opts.initial_flow or 0}}
  local function tick()
    if not s.active then s.rpm=math.max(0,s.rpm-cfg.ramp_rate*2); s.flow_actual=0
    else
      s.flow_actual=s.flow_actual+(s.flow_target-s.flow_actual)*0.3
      local trpm=cfg.target_rpm*math.min(1,s.flow_actual/math.max(1,cfg.flow_capacity/2))
      s.rpm=math.max(0,math.min(cfg.max_rpm,s.rpm+(trpm-s.rpm)*0.1))
      if s.rpm>=cfg.coil_engage_rpm then s.coil_engaged=true end
      if s.rpm<cfg.coil_engage_rpm*0.9 then s.coil_engaged=false end
    end
    local lag=math.max(1,cfg.readback_lag)
    s._rb.rpm=s._rb.rpm+(s.rpm-s._rb.rpm)/lag
    s._rb.flow=s._rb.flow+(s.flow_actual-s._rb.flow)/lag
  end
  local api={}; api.tick=tick
  function api.getActive() return s.active end
  function api.setActive(v) s.active=v==true end
  function api.getRotorSpeed() return s._rb.rpm end
  function api.getFluidFlowRate() return s._rb.flow end
  function api.getFluidFlowRateMax() return cfg.flow_capacity end
  function api.isCoilEngaged() return s.coil_engaged end
  function api.setCoilEngaged(v) s.coil_engaged=v==true end
  function api.setFluidFlowRateTarget(r) s.flow_target=math.max(0,math.min(cfg.flow_capacity,r)) end
  function api.getFluidFlowRateTarget() return s.flow_target end
  function api.getEnergyProduced() if not s.coil_engaged then return 0 end; return s.rpm*cfg.energy_per_rpm end
  function api.getEnergyProducedLastTick() return api.getEnergyProduced() end
  function api._state() return s end; function api._cfg() return cfg end
  return api
end
return M
