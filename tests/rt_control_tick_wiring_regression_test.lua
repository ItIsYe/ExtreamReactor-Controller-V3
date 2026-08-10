local f=assert(io.open('xreactor/nodes/rt/main.lua','r'));local s=f:read('*a');f:close()
local start=assert(s:find('local function control_tick()',1,true)); local stop=assert(s:find('-- ── Command-Handler',start,true)); local b=s:sub(start,stop)
local order={
  'if rt_update_quiescing then return end',
  'module_lifecycle.update_module_states(make_lifecycle_ctx())',
  'module_lifecycle.process_startup(make_lifecycle_ctx())',
  'reactor_control.updateReactorControl(ctx)',
  'turbine_control.updateControl(ctx)',
  'writeback_ctx()',
}
local last=0; for _,t in ipairs(order) do local i=assert(b:find(t,1,true),'missing control tick delegation '..t); assert(i>last,'control tick safety/order drift at '..t); last=i end
print('rt_control_tick_wiring_regression_test.lua: ok')
