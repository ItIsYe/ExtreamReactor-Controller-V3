package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')

-- Der Update-Quiesce der RT-Node gilt erst als bestaetigt, wenn die Hardware
-- den sicheren Zustand zuruecklesen laesst: Staebe 100 und Reaktor aus,
-- Turbinen mit Flow 0, aus und Coil eingehaengt.
--
-- Seit v814 laeuft er NAMENSBASIERT (peripheral.call ueber die Adapter),
-- nicht mehr ueber die wrap-Handles aus ctx.peripherals und den
-- Faehigkeiten-Cache, die die Discovery einmal schreibt. Abschnitt 3 prueft
-- genau den Fall, an dem das scheiterte: veraltete Handles und ein
-- veralteter Cache, waehrend die Peripherie laengst wieder vollstaendig ist.

local rc=require('nodes.rt.reactor_control')
local tc=require('nodes.rt.turbine_control')

-- Peripherie wie in CC:Tweaked: peripheral.call(name, methode) schlaegt die
-- Methode zur Laufzeit nach; eine unbekannte wirft.
local devices={}
_G.peripheral={
  isPresent=function(n) return devices[n]~=nil end,
  getType=function(n) return devices[n] and devices[n].__type or nil end,
  getMethods=function(n)
    local d=devices[n]; if not d then return nil end
    local out={}; for k,v in pairs(d) do if type(v)=='function' then out[#out+1]=k end end
    table.sort(out); return out
  end,
  call=function(n,m,...)
    local d=devices[n]
    if not d or type(d[m])~='function' then error('No such method '..tostring(m)) end
    return d[m](...)
  end,
}
-- wrap() wie in CC:Tweaked: eine Tabelle mit genau den Methoden, die es
-- beim Einbinden gab -- daher veraltet ein Handle, wenn die Liste spaeter
-- waechst.
peripheral.wrap=function(n)
  if not devices[n] then return nil end
  local handle={}
  for _,m in ipairs(peripheral.getMethods(n)) do
    handle[m]=function(...) return peripheral.call(n,m,...) end
  end
  return handle
end
local utils=require('core.utils')
local reactor_adapter=require('adapters.reactor')
local turbine_adapter=require('adapters.turbine')

-- ══ 1. Reaktor ════════════════════════════════════════════════════════════
local rod_read=100
local reactor={__type='BigReactors-Reactor',active=true}
reactor.setActive=function(v) reactor.active=v end
reactor.getActive=function() return reactor.active end
devices.R1=reactor
local rctx={config={reactors={'R1'}},CONFIG={LOG_PREFIX='RT'},utils=utils,reactor_ctrl={},
  adapters={reactor={apply_rod_level=function(_,v) return v==100 end,read_control_rods=function() return rod_read end,
    set_active=reactor_adapter.set_active}}}
local ok=rc.apply_update_quiesce(rctx)
assert(ok==true and reactor.active==false,'reactor quiesce needs rods=100 readback and inactive confirmation')
rod_read=90
assert(rc.apply_update_quiesce(rctx)==false,'unsafe rod readback must keep RT quiesce pending')
rod_read=100

-- ══ 2. Turbine ════════════════════════════════════════════════════════════
local flow=0; local active=true; local coil=false
local turbine={__type='BigReactors-Turbine',
  setFluidFlowRateMax=function(v) flow=v end,getFluidFlowRateMax=function() return flow end,
  setActive=function(v) active=v end,getActive=function() return active end,
  setInductorEngaged=function(v) coil=v end,getInductorEngaged=function() return coil end,
  getRotorSpeed=function() return 900 end,getEnergyProducedLastTick=function() return 1000 end}
devices.T1=turbine
local tctx={config={turbines={'T1'}},CONFIG={LOG_PREFIX='RT',MIN_FLOW=0,MAX_FLOW=2000},utils=utils,
  adapters={turbine=turbine_adapter},capability_cache={turbines={}},turbine_ctrl_store={},log=function() end,
  safe_wrapped_call=function(obj,m,...) return pcall(obj[m],...) end,
  safety={clamp=function(v,a,b) return math.max(a,math.min(b,v)) end}}
flow=1500
local tok=tc.apply_update_quiesce(tctx)
assert(tok==true and flow==0 and active==false and coil==true,'turbine quiesce must confirm zero flow/inactive/coil')
local real_get=turbine.getFluidFlowRateMax
turbine.getFluidFlowRateMax=function() return 50 end
assert(tc.apply_update_quiesce(tctx)==false,'nonzero flow readback must keep RT quiesce pending')
turbine.getFluidFlowRateMax=real_get

-- Eine verschwundene Turbine darf nie als sicher gelten.
devices.T1=nil
assert(tc.apply_update_quiesce(tctx)==false,'a missing turbine must keep RT quiesce pending')
devices.T1=turbine

-- ══ 3. Veraltete Handles und veralteter Cache (der Feldfall) ══════════════
--
-- Nach dem Chunk-Laden kam die Anlage zuerst mit verkuerzten Methodenlisten
-- zurueck. Discovery hatte die wrap-Handles und den Faehigkeiten-Cache in
-- diesem Zustand geschrieben und erneuert sie nicht, solange der Name
-- gebunden bleibt. Bis v813 wurde der Quiesce so nie bestaetigt.
do
  flow=1500; active=true; coil=false
  local stale_turbine_ctx={config={turbines={'T1'}},CONFIG={LOG_PREFIX='RT',MIN_FLOW=0,MAX_FLOW=2000},utils=utils,
    adapters={turbine=turbine_adapter},turbine_ctrl_store={},log=function() end,
    peripherals={turbines={T1={getRotorSpeed=turbine.getRotorSpeed}}},
    capability_cache={turbines={T1={getRotorSpeed=true}}},
    safe_wrapped_call=function(obj,m,...) return pcall(obj[m],...) end,
    safety={clamp=function(v,a,b) return math.max(a,math.min(b,v)) end}}
  assert(tc.apply_update_quiesce(stale_turbine_ctx)==true and flow==0 and active==false and coil==true,
    'turbine quiesce must not depend on stale wrap handles or a stale capability cache')

  reactor.active=true
  local stale_reactor_ctx={config={reactors={'R1'}},CONFIG={LOG_PREFIX='RT'},utils=utils,reactor_ctrl={},
    peripherals={reactors={R1={}}},
    adapters={reactor={apply_rod_level=function(_,v) return v==100 end,read_control_rods=function() return rod_read end,
      set_active=reactor_adapter.set_active}}}
  assert(rc.apply_update_quiesce(stale_reactor_ctx)==true and reactor.active==false,
    'reactor quiesce must not depend on a stale wrap handle')
end

print('rt_update_quiesce_hardware_confirmation_test.lua: ok')
