package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local sends = 0
local comms = { send_command = function() sends = sends + 1 end }

local desired = {
  target_rpm = 900,
  power_target = 800,
  steam_target = 4000,
  enable_reactors = true,
  enable_turbines = true,
  assignment_reason = 'DEMAND_ACTIVE',
  assignment_source = 'master.rt_sync.plan',
  assignment_rank = 1,
  assignment_state = 'active',
  controllable = true
}

local node = {
  id = 'RT-9',
  role = constants.roles.RT_NODE,
  mode = 'MASTER',
  status = constants.status_levels.OK,
  state = constants.node_states.RUNNING,
  output = 600,
  last_setpoints = rt_sync.normalize_setpoints(desired),
  last_setpoints_ts = os.epoch('utc') - 5000,
  last_command_result = {
    ok = true,
    at = os.epoch('utc'),
    command_target = constants.command_targets.SET_SETPOINTS,
    command_value = rt_sync.normalize_setpoints(desired),
    transition = 'APPLIED'
  }
}

rt_sync.sync_rt_node({
  comms = comms,
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
  nodes = { ['RT-9'] = node },
  power_target = 800,
  rt_global_off = false,
  trigger = 'coalesced:ack_applied,status',
  log = function() end
}, node)

if sends ~= 0 then
  error('ack_applied with unchanged target must not resend setpoints, got sends=' .. tostring(sends))
end

print('rt_sync_ack_applied_no_resend_semantics_test.lua: ok')
