package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local rt_sync = require('master.rt_sync')

local sends = 0
local comms = {
  send_command = function(_, _, payload)
    sends = sends + 1
  end
}

local node = {
  id = 'RT-52',
  role = constants.roles.RT_NODE,
  mode = 'MASTER',
  status = constants.status_levels.OK,
  state = constants.node_states.RUNNING,
  output = 100,
  shutdown_workflow = { requested_at = os.epoch('utc') - 1000, stage = 'REQUESTED' },
  last_setpoints = {
    assignment_state = 'shutdown', shutdown_stage = 'REQUEST_OFF', desired_node_state = constants.node_states.OFF,
    target_rpm = 900, power_target = 0, steam_target = 0, enable_reactors = false, enable_turbines = false
  },
  last_setpoints_ts = os.epoch('utc') - 5000,
  last_command_result = {
    ok = true,
    at = os.epoch('utc'),
    command_target = constants.command_targets.SET_SETPOINTS,
    shutdown_stage = 'REQUEST_OFF',
    desired_node_state = constants.node_states.OFF,
    transition = 'REQUESTED'
  }
}

rt_sync.sync_rt_node({
  comms = comms,
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
  nodes = { ['RT-52'] = node },
  power_target = 0,
  rt_global_off = false,
  log = function() end
}, node)

if sends ~= 0 then
  error('shutdown ack dedupe regression: no new command should be queued after accepted shutdown ack')
end

node.shutdown_workflow = nil
node.last_command_result = nil
node.last_setpoints.assignment_state = 'shed'
node.last_setpoints.desired_node_state = constants.node_states.LIMITED
node.last_setpoints.shutdown_stage = 'RAMPDOWN'
sends = 0
rt_sync.sync_rt_node({
  comms = comms,
  config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
  nodes = { ['RT-52'] = node },
  power_target = 0,
  rt_global_off = false,
  log = function() end
}, node)
if sends ~= 0 then
  error('shed dedupe regression: identical rampdown intent must not enqueue duplicate command')
end

print('rt_sync_ack_dedupe_regression_test.lua: ok')
