package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local rc=require('nodes.rt.reactor_control')
local function clamp(v,a,b)return math.max(a,math.min(b,v))end
local ctx={config={rails={reactor_rods={min=130,max=-20}}},CONFIG={ROD_MIN=0,ROD_MAX=100},safety={clamp=clamp}}
local lo,hi=rc.get_effective_regulator_rod_caps(ctx)
assert(lo==0 and hi==100,'inverted/out-of-range config must normalize to physical rod range')
ctx.config.rails.reactor_rods={min=85,max=20}; lo,hi=rc.get_effective_regulator_rod_caps(ctx)
assert(lo==20 and hi==85,'configured cap order must normalize deterministically')
assert(rc.clamp_rods(ctx,-50,false)==0 and rc.clamp_rods(ctx,200,false)==100,'normal rod targets must stay within physical rails')
print('reactor_rod_config_clamp_regression_test.lua: ok')
