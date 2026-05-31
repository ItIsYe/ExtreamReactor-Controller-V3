package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local health = require('core.health')
local handlers = require('master.message_handlers')

local nodes = {}
local sync_calls = 0
local dirty_reasons = {}

local handler = handlers.new({
  constants = constants,
  utils = require('core.utils'),
  health = health,
  nodes = nodes,
  comms = function() return { get_peers = function() return {} end } end,
  sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end, active = nil },
  sync_rt_node = function() sync_calls = sync_calls + 1 end,
  mark_rt_sync_dirty = function(node, reason)
    dirty_reasons[#dirty_reasons + 1] = tostring(reason)
  end,
  add_alarm = function() end,
  master_time_label = function() return '12:00:00' end,
  log = function() end
})

handler.update_node({ type = constants.message_types.HELLO, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = {} })
handler.update_node({ type = constants.message_types.HEARTBEAT, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { state = constants.node_states.RUNNING } })
handler.update_node({ type = constants.message_types.STATUS, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = {
  status = constants.status_levels.OK,
  mode = 'MASTER',
  health = { status = constants.status_levels.OK, reasons = {} }
} })
handler.update_node({
  type = constants.message_types.ACK_APPLIED,
  sender_id = 'rt-1',
  node_id = 'rt-1',
  role = constants.roles.RT_NODE,
  payload = { result = { ok = true, command_target = constants.command_targets.SET_SETPOINTS, command_value = {} } }
})

if sync_calls ~= 0 then
  error('expected no direct sync_rt_node calls from handler event paths')
end
if #dirty_reasons ~= 4 then
  error('expected 4 coalesced dirty triggers, got ' .. tostring(#dirty_reasons))
end

local expected = { hello = true, heartbeat = true, status = true, ack_applied = true }
for _, reason in ipairs(dirty_reasons) do
  expected[reason] = nil
end
for missing, present in pairs(expected) do
  if present then error('missing dirty marker reason: ' .. tostring(missing)) end
end

print('master_rt_sync_trigger_coalescing_guard_test.lua: ok')
