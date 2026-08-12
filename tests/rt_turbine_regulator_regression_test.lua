package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local regulator=require('core.turbine_regulator'); local rails=require('core.control_rails')
local function assert_eq(a,e,m) if a~=e then error((m or'fail')..': expected='..tostring(e)..' actual='..tostring(a)) end end
if regulator.startup_reached_target(895,900,20)~=true then error('within tolerance') end
if regulator.startup_reached_target(875,900,20)~=false then error('below tolerance') end
local flow_cfg={deadband_up=20,deadband_down=20,hysteresis_up=0,hysteresis_down=0,max_step_up=250,max_step_down=250,min_step_up=50,min_step_down=50,step_per_rpm_up=0.5,step_per_rpm_down=0.5,adaptive_step=true,cooldown_s=0,min=0,max=2000,ema_alpha=1.0}
local state=rails.new_state()
local flow=rails.step(500,900-800,state,flow_cfg,os.clock())
if type(flow)~='number' then error('step must return numeric flow') end
print('rt_turbine_regulator_regression_test.lua: ok')
