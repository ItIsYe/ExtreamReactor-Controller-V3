package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local profile = require('master.runtime_ops_profile')
local constants = require('shared.constants')
local function assert_eq(a, b, m) if a ~= b then error((m or 'assert_eq') .. ': expected=' .. tostring(b) .. ' actual=' .. tostring(a)) end end

local runtime = {
  libs = { constants = constants },
  state = {
    power_target = 999,
    nodes = {
      fresh = {
        role = constants.roles.RT_NODE, status = 'OK', stale = false, offline = false,
        capacity_ready = true, capacity_max = 500, actual_output = 250,
      },
      stale = {
        role = constants.roles.RT_NODE, status = 'OK', stale = true, offline = false,
        capacity_ready = true, capacity_max = 5000, actual_output = 4000,
      },
      offline = {
        role = constants.roles.RT_NODE, status = constants.status_levels.OFFLINE,
        capacity_ready = true, capacity_max = 7000, actual_output = 6000,
      },
    }
  }
}

local base, source = profile.estimate_base_power(runtime)
assert_eq(base, 500, 'only fresh ready RT capacity may contribute')
assert_eq(source, 'learned-capacity', 'fresh learned capacity should be preferred')

runtime.state.nodes.fresh = nil
base, source = profile.estimate_base_power(runtime)
assert_eq(base, 0, 'no available RT must not revive previous target as capacity')
assert_eq(source, 'no-available-rt', 'unavailable fleet should be explicit')

runtime.state.nodes = {
  fresh_not_ready = {
    role = constants.roles.RT_NODE, status = 'OK', stale = false, offline = false,
    capacity_ready = false, capacity_max = 900, actual_output = 300,
  }
}
base, source = profile.estimate_base_power(runtime)
assert_eq(base, 300, 'not-ready learned capacity must be ignored in favor of fresh measured output')
assert_eq(source, 'measured', 'measured output should be fallback while capacity learning is not ready')

print('master_profile_stale_capacity_test.lua: ok')
