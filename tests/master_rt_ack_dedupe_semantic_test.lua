package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local sends = 0
local comms = { send_command = function() sends = sends + 1 end }

local desired = rt_sync.normalize_setpoints({
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
})

local node = {
  id = 'RT-9', role = constants.roles.RT_NODE, mode = 'MASTER',
  status = constants.status_levels.OK, state = constants.node_states.RUNNING, output = 600,
  last_setpoints = desired, last_setpoints_ts = os.epoch('utc') - 5000,
  last_command_result = {
    ok = true, at = os.epoch('utc'), command_target = constants.command_targets.SET_SETPOINTS,
    command_value = desired, transition = 'APPLIED'
  }
}

local ctx = {
  comms = comms,
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
  nodes = { ['RT-9'] = node },
  power_target = 800,
  rt_global_off = false,
  trigger = 'coalesced:ack_applied,status',
  log = function() end
}

rt_sync.sync_rt_node(ctx, node)
if sends ~= 0 then error('matching successful ACK must dedupe resend') end

node.last_command_result = {
  ok = true, at = os.epoch('utc') - 6000, command_target = constants.command_targets.SET_SETPOINTS,
  command_value = rt_sync.normalize_setpoints({ power_target = 0 }), transition = 'APPLIED'
}
rt_sync.sync_rt_node(ctx, node)
if sends ~= 1 then error('stale/non-matching ACK must not block needed resend') end

node.last_setpoints = rt_sync.normalize_setpoints({
  target_rpm = 900, power_target = 0, steam_target = 0, enable_reactors = false, enable_turbines = false,
  assignment_reason = 'STANDBY', assignment_source = 'master.rt_sync.plan', assignment_rank = 2, assignment_state = 'standby',
  controllable = true, desired_node_state = constants.node_states.LIMITED
})
node.last_setpoints_ts = os.epoch('utc') - 5000
node.last_command_result = {
  ok = true, at = os.epoch('utc'), command_target = constants.command_targets.POWER_TARGET,
  command_value = node.last_setpoints, transition = 'APPLIED'
}
ctx.power_target = 0
rt_sync.sync_rt_node(ctx, node)
if sends ~= 1 then error('matching legacy-target ACK in standby intent must stay deduped') end

print('master_rt_ack_dedupe_semantic_test.lua: ok')
