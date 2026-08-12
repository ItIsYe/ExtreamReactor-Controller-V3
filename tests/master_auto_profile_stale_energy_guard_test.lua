package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local ops = require('master.runtime_ops_profile')
local constants = require('shared.constants')
os.epoch = function() return 5000 end

local trend_values = {}
local trends = {}
function trends:push(name, value)
  trend_values[name] = trend_values[name] or {}
  trend_values[name][#trend_values[name] + 1] = value
  return false
end
function trends:values(name) return trend_values[name] or {} end

local runtime = {
  libs = {
    constants = constants,
    profiles = {
      BASELOAD = { target = 0.6, ramp = 'NORMAL' },
      PEAK = { target = 1.0, ramp = 'FAST' },
      IDLE = { target = 0.2, ramp = 'SLOW' },
    },
  },
  state = {
    last_trend_sample = 0,
    nodes = {
      E1 = { role = constants.roles.ENERGY_NODE, stored = 0, capacity = 1000, data_stale = true },
    },
    auto_profile = true,
    active_profile = 'BASELOAD',
    power_target = 600,
    trend_cache = {},
  },
  refs = { trends = trends, sequencer = { ramp_profile = 'NORMAL' } },
  config = {},
  log = function() end,
  mark_rt_sync_dirty = function() end,
  flush_rt_sync_queue = function() end,
}

ops.sample_trends(runtime)
assert(runtime.state.active_profile == 'BASELOAD',
  'stale-only ENERGY data must not force a profile transition')
assert(runtime.state.power_target == 600,
  'stale-only ENERGY data must not change the current power target')

print('master_auto_profile_stale_energy_guard_test.lua: ok')
