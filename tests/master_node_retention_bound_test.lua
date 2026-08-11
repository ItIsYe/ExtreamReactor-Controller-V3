package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local runtime_ops = require('master.runtime_ops_rt')
local constants = require('shared.constants')
local health = require('core.health')

os.epoch = function() return 100000 end
local runtime = {
  state = { nodes = {
    ['STALE-1'] = {
      id = 'STALE-1', last_seen = 1000, status = constants.status_levels.OK,
      managed = true,
    },
  } },
  refs = { comms = { get_peers = function() return {} end } },
  config = {
    heartbeat_interval = 1,
    comms = { peer_timeout_s = 2, peer_down_grace_s = 0 },
  },
  tuning = { node_offline_purge_after_ms = 5000 },
  libs = { constants = constants, health = health },
  log = function() end,
}

runtime_ops.check_timeouts(runtime)
assert(runtime.state.nodes['STALE-1'] == nil,
  'node older than offline retention must be removed, not retained forever')

print('master_node_retention_bound_test.lua: ok')
