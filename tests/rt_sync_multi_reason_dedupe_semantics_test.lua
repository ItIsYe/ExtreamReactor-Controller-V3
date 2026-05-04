package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local sends = 0
local comms = {
  send_command = function(_, _, _)
    sends = sends + 1
  end
}

local node = {
  id = 'RT-42',
  role = constants.roles.RT_NODE,
  mode = 'MASTER',
  status = constants.status_levels.OK,
  state = constants.node_states.RUNNING,
  output = 350,
  shutdown_workflow = {}
}

local ctx = {
  comms = comms,
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
  nodes = { ['RT-42'] = node },
  power_target = 1200,
  rt_global_off = false,
  log = function() end
}

rt_sync.sync_rt_node(setmetatable({ trigger = 'coalesced:hello,heartbeat,status' }, { __index = ctx }), node)
if sends ~= 1 then
  error('first coalesced sync should send exactly once, got ' .. tostring(sends))
end

-- simulate later flush with merged different reasons but same desired target
node.last_setpoints_ts = os.epoch('utc') - 3000
rt_sync.sync_rt_node(setmetatable({ trigger = 'coalesced:ack_applied,status' }, { __index = ctx }), node)
if sends ~= 1 then
  error('second coalesced sync with unchanged desired setpoints must be deduped, got sends=' .. tostring(sends))
end

print('rt_sync_multi_reason_dedupe_semantics_test.lua: ok')
