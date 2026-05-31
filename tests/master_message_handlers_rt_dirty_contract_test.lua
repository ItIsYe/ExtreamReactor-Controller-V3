package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
if not os.epoch then
  local fake_now = 200000
  os.epoch = function()
    fake_now = fake_now + 100
    return fake_now
  end
end

local constants = require('shared.constants')
local handlers = require('master.message_handlers')
local health = require('core.health')
local rt_sync = require('master.rt_sync')

local utils = require('core.utils')
local node_id = utils.normalize_node_id('rt-1')
local nodes = { [node_id] = { id = node_id, role = constants.roles.RT_NODE, last_setpoints = rt_sync.normalize_setpoints({ power_target = 100 }) } }
local dirty = {}
local calls = 0
local sync_attempts = 0
local h = handlers.new({
  constants = constants,
  utils = utils,
  health = health,
  nodes = nodes,
  comms = function() return {
    get_peers = function() return {} end,
    send_command = function() sync_attempts = sync_attempts + 1 end
  } end,
  sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end, active = nil },
  mark_rt_sync_dirty = function(_, reason) calls = calls + 1; dirty[reason] = (dirty[reason] or 0) + 1 end,
  add_alarm = function() end,
  master_time_label = function() return '12:00:00' end,
  log = function() end
})

h.update_node({ type = constants.message_types.HELLO, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = {} })
h.update_node({ type = constants.message_types.HEARTBEAT, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { state = constants.node_states.RUNNING } })
h.update_node({ type = constants.message_types.STATUS, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { status = constants.status_levels.OK, mode = 'MASTER', health = { status = constants.status_levels.OK, reasons = {} } } })
h.update_node({ type = constants.message_types.ACK_APPLIED, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, ack_for = 'SET_SETPOINTS', payload = { result = { ok = true, command_target = constants.command_targets.SET_SETPOINTS, command_value = rt_sync.normalize_setpoints({ power_target = 100 }) } } })

if dirty.hello ~= 1 or dirty.heartbeat ~= 1 or dirty.status ~= 1 then
  error('hello/heartbeat/status must each dirty mark exactly once')
end
if dirty.ack_applied then
  error('redundant ack_applied should not dirty mark outside workflow follow-up')
end
if sync_attempts ~= 0 then
  error('message handler must not directly send sync commands; only dirty-mark contract is allowed')
end

nodes[node_id].shutdown_workflow = { stage = 'WAITING_STATE' }
h.update_node({ type = constants.message_types.ACK_APPLIED, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, ack_for = 'SET_SETPOINTS', payload = { result = { ok = true, transition = 'REQUESTED', command_target = constants.command_targets.SET_SETPOINTS, command_value = rt_sync.normalize_setpoints({ power_target = 100 }) } } })

if dirty.ack_applied ~= 1 then
  error('workflow REQUESTED ack must dirty mark once for shutdown follow-up')
end
if calls ~= 4 then
  error('expected exactly 4 dirty marks including workflow follow-up, got ' .. tostring(calls))
end
if sync_attempts ~= 0 then
  error('workflow follow-up ack must still not trigger direct sync storms from handler')
end

print('master_message_handlers_rt_dirty_contract_test.lua: ok')
