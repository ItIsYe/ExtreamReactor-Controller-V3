local function assert_true(v,m) if not v then error(m or 'fail') end end
local function read(p) local f=io.open(p,'r'); if not f then error('open '..p) end; local c=f:read('*a'); f:close(); return c end
local combined=read('xreactor/nodes/rt/main.lua').."\n"..read('xreactor/nodes/rt/turbine_control.lua').."\n"..read('xreactor/nodes/rt/config_normalizer.lua')
assert_true(combined:find('MIN_FLOW%s*=%s*0',1,false)~=nil,'runtime minimum turbine flow must stay at 0')
assert_true(combined:find('MAX_FLOW%s*=',1,false)~=nil,'runtime maximum turbine flow must be defined')
assert_true(combined:find('START_FLOW%s*=',1,false)~=nil,'startup turbine flow must be defined')
assert_true(combined:find('adaptive_step',1,true)~=nil,'turbine rail adaptive_step must exist')
assert_true(combined:find('reason=',1,true)~=nil,'turbine debug log must include reason field')
assert_true(combined:find('clamp_min',1,true)~=nil or combined:find('MIN_FLOW',1,true)~=nil,'clamp min')
assert_true(combined:find('clamp_max',1,true)~=nil or combined:find('MAX_FLOW',1,true)~=nil,'clamp max')
assert_true(combined:find('TARGET_TRIM_DOWN',1,true)~=nil,'TARGET_TRIM_DOWN')
assert_true(combined:find('confirmed_at_max',1,true)~=nil,'confirmed_at_max')
print('rt_turbine_flow_range_config_regression_test.lua: ok')
