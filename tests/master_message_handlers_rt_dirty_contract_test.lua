package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local handlers = require('master.message_handlers')
local health = require('core.health')

local nodes = { ['RT-1'] = { id = 'RT-1', role = constants.roles.RT_NODE, last_setpoints = { power_target = 100 } } }
local dirty = {}
local calls = 0
local h = handlers.new({
  constants = constants,
  utils = require('core.utils'),
  health = health,
  nodes = nodes,
  comms = function() return { get_peers = function() return {} end } end,
  sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end, active = nil },
  mark_rt_sync_dirty = function(_, reason) calls = calls + 1; dirty[reason] = (dirty[reason] or 0) + 1 end,
  add_alarm = function() end,
  master_time_label = function() return '12:00:00' end,
  log = function() end
})

h.update_node({ type = constants.message_types.HELLO, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = {} })
h.update_node({ type = constants.message_types.HEARTBEAT, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { state = constants.node_states.RUNNING } })
h.update_node({ type = constants.message_types.STATUS, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { status = constants.status_levels.OK, mode = 'MASTER', health = { status = constants.status_levels.OK, reasons = {} } } })
h.update_node({ type = constants.message_types.ACK_APPLIED, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, ack_for = 'SET_SETPOINTS', payload = { result = { ok = true, command_target = constants.command_targets.SET_SETPOINTS, command_value = { power_target = 100 } } } })

if dirty.hello ~= 1 or dirty.heartbeat ~= 1 or dirty.status ~= 1 then
  error('hello/heartbeat/status must each dirty mark exactly once')
end
if dirty.ack_applied then
  error('redundant ack_applied should not dirty mark')
end
if calls ~= 3 then
  error('expected exactly 3 dirty marks, got ' .. tostring(calls))
end

print('master_message_handlers_rt_dirty_contract_test.lua: ok')
