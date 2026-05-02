local rt_sync = require('master.rt_sync')
local constants = require('shared.constants')

local sent = 0
local ctx = {
  plan = { nodes = { { id = 'RT-1', controllable = true, assignment_reason = 'SHUTDOWN_READY', mode = 'MASTER', status = 'OK', setpoints = rt_sync.normalize_setpoints({
    target_rpm = 900, power_target = 0, steam_target = 0, enable_reactors = false, enable_turbines = false, assignment_reason = 'SHUTDOWN_READY', assignment_source = 'master.rt_sync.plan', assignment_state = 'shutdown', assignment_rank = 2, controllable = true, shutdown_stage = 'REQUEST_OFF', desired_node_state = constants.node_states.OFF
  }) } } },
  comms = { send_command = function() sent = sent + 1 end },
  log = function() end,
  config = {}
}
local node = { id = 'RT-1', role = constants.roles.RT_NODE, mode = 'MASTER', state = constants.node_states.LIMITED }
rt_sync.sync_rt_node(ctx, node)
if sent ~= 1 then error('first sync must send exactly one command') end
node.last_command_result = { ok = true, command_target = constants.command_targets.SET_SETPOINTS, desired_node_state = constants.node_states.OFF, transition = 'REQUESTED' }
rt_sync.sync_rt_node(ctx, node)
if sent ~= 1 then error('ack requested shutdown must suppress resend spam') end
print('rt_sync_dedupe_ack_guard_test.lua: ok')
