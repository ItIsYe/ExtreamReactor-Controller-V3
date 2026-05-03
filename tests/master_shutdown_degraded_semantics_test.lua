local handlers = require('master.message_handlers')
local constants = require('shared.constants')
local health = require('core.health')
local utils = require('core.utils')

local nodes = { ['RT-1'] = { id='RT-1', role=constants.roles.RT_NODE, state=constants.node_states.OFF, last_setpoints={ assignment_state='shutdown' }, health={status=health.status.OK,reasons={}}, status=health.status.OK } }
local h = handlers.new({
  constants = constants,
  utils = utils,
  health = health,
  nodes = nodes,
  comms = function() return { get_peers = function() return {} end } end,
  sequencer = { enqueue=function() end, notify_stable=function() end, notify_ack=function() end },
  sync_rt_node = function() end,
  add_alarm = function() end,
  master_time_label = function() return 't' end,
  log = function() end
})

h.update_node({ type = constants.message_types.STATUS, sender_id='RT-1', node_id='RT-1', role=constants.roles.RT_NODE, proto_ver=constants.proto_ver, payload={
  state = constants.node_states.OFF,
  health = { status = health.status.DEGRADED, reasons = { health.reasons.CONTROL_DEGRADED } }
}})
if nodes['RT-1'].status ~= health.status.OK then error('controlled shutdown must suppress non-hard degraded status') end

nodes['RT-1'].last_setpoints = nil
nodes['RT-1'].shutdown_workflow = { stage = 'WAITING_STATE' }
nodes['RT-1'].state = constants.node_states.RUNNING
h.update_node({ type = constants.message_types.HEARTBEAT, sender_id='RT-1', node_id='RT-1', role=constants.roles.RT_NODE, proto_ver=constants.proto_ver, payload={
  state = constants.node_states.RUNNING
}})
if nodes['RT-1'].status ~= health.status.OK then error('shutdown workflow WAITING_STATE must keep degraded suppressed during heartbeat even before OFF state') end
print('master_shutdown_degraded_semantics_test.lua: ok')
