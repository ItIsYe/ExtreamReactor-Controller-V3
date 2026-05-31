package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local sends = 0
local comms = { send_command = function() sends = sends + 1 end }

local previous_target = rt_sync.normalize_setpoints({
  target_rpm = 900,
  power_target = 500,
  steam_target = 3000,
  enable_reactors = true,
  enable_turbines = true,
  assignment_reason = 'DEMAND_ACTIVE',
  assignment_source = 'master.rt_sync.plan',
  assignment_rank = 1,
  assignment_state = 'active',
  controllable = true
})

local node = {
  id = 'RT-88',
  role = constants.roles.RT_NODE,
  mode = 'MASTER',
  status = constants.status_levels.OK,
  state = constants.node_states.RUNNING,
  output = 400,
  last_setpoints = previous_target,
  last_setpoints_ts = os.epoch('utc'),
  last_command_result = {
    ok = true,
    at = os.epoch('utc') - 10000,
    command_target = constants.command_targets.SET_SETPOINTS,
    command_value = rt_sync.normalize_setpoints({
      target_rpm = 900,
      power_target = 1200,
      steam_target = 4000,
      enable_reactors = true,
      enable_turbines = true,
      assignment_reason = 'DEMAND_ACTIVE',
      assignment_source = 'master.rt_sync.plan',
      assignment_rank = 1,
      assignment_state = 'active',
      controllable = true
    }),
    transition = 'APPLIED'
  }
}

rt_sync.sync_rt_node({
  comms = comms,
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
  nodes = { ['RT-88'] = node },
  power_target = 1200,
  rt_global_off = false,
  trigger = 'coalesced:status,ack_applied',
  log = function() end
}, node)

if sends ~= 1 then
  error('stale ack must not block resend for newer desired setpoints, got sends=' .. tostring(sends))
end

print('rt_sync_stale_ack_does_not_block_resend_test.lua: ok')
