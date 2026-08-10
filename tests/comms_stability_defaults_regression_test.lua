package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local comms=require('core.comms')
local master=dofile('xreactor/master/config.lua')
local energy=dofile('xreactor/nodes/energy/config.lua')
local mc=assert(master.comms,'master comms missing'); local ec=assert(energy.comms,'energy comms missing')
assert(mc.peer_down_grace_s==5.0 and mc.peer_down_min_observations==2
  and mc.peer_up_debounce_s==1.5 and mc.peer_up_min_observations==2,
  'master peer hysteresis defaults drifted')
assert(ec.peer_down_grace_s==10.0 and ec.peer_down_min_observations==3
  and ec.peer_up_debounce_s==3.0 and ec.peer_up_min_observations==3,
  'energy peer hysteresis defaults drifted')
assert(energy.matrix_metric_poll_interval==12.0,'energy matrix poll interval drifted')
local sanitized=comms.sanitize_config({peer_timeout_s=1,peer_down_grace_s=-5,peer_up_debounce_s=-1,peer_up_min_observations=0})
assert(sanitized.peer_down_grace_s>=0 and sanitized.peer_up_debounce_s>=0 and sanitized.peer_up_min_observations>=1,
  'comms sanitizer must keep stability bounds safe')
print('comms_stability_defaults_regression_test.lua: ok')
