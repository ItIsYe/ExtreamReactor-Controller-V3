package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local rc=require('nodes.rt.reactor_control')
local tc=require('nodes.rt.turbine_control')
_G.peripheral={getMethods=function() return {'setFluidFlowRateMax','getFluidFlowRateMax','setActive','getActive','setInductorEngaged','getInductorEngaged'} end}
local rod_read=100
local reactor={active=true}
reactor.setActive=function(v) reactor.active=v end
reactor.getActive=function() return reactor.active end
local rctx={config={reactors={'R1'}},CONFIG={LOG_PREFIX='RT'},peripherals={reactors={R1=reactor}},utils={safe_wrap=function() return reactor end},reactor_ctrl={},
  adapters={reactor={apply_rod_level=function(_,v) return v==100 end,read_control_rods=function() return rod_read end}}}
local ok=rc.apply_update_quiesce(rctx)
assert(ok==true and reactor.active==false,'reactor quiesce needs rods=100 readback and inactive confirmation')
rod_read=90
assert(rc.apply_update_quiesce(rctx)==false,'unsafe rod readback must keep RT quiesce pending')

local flow=0; local active=true; local coil=false
local turbine={setFluidFlowRateMax=function(v) flow=v end,getFluidFlowRateMax=function() return flow end,setActive=function(v) active=v end,getActive=function() return active end,
  setInductorEngaged=function(v) coil=v end,getInductorEngaged=function() return coil end}
local tctx={config={turbines={'T1'}},CONFIG={START_FLOW=100,TURBINE_MODE_RAMP='RAMP'},peripherals={turbines={T1=turbine}},utils={safe_wrap=function() return turbine end},
  capability_cache={turbines={}},turbine_ctrl_store={},autonom_state={turbines={}},binding={missing_devices_message=function() return '' end,build_policy=function() return {} end},
  runtime_config={configured_reactors={},configured_turbines={}},log=function() end,safe_wrapped_call=function(obj,m,...) return pcall(obj[m],...) end,
  safety={clamp=function(v,a,b) return math.max(a,math.min(b,v)) end},CONFIG={START_FLOW=100,TURBINE_MODE_RAMP='RAMP',MIN_FLOW=0,MAX_FLOW=2000}}
local tok=tc.apply_update_quiesce(tctx)
assert(tok==true and flow==0 and active==false and coil==true,'turbine quiesce must confirm zero flow/inactive/coil')
turbine.getFluidFlowRateMax=function() return 50 end
assert(tc.apply_update_quiesce(tctx)==false,'nonzero flow readback must keep RT quiesce pending')
print('rt_update_quiesce_hardware_confirmation_test.lua: ok')
