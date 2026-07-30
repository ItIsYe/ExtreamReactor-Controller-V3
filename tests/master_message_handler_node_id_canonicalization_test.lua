package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local health = require('core.health')
local handlers = require('master.message_handlers')

local nodes = {
  ['ENERGY-1'] = {
    id = 'ENERGY-1',
    role = constants.roles.ENERGY_NODE,
    status = constants.status_levels.OK,
    health = health.new({})
  }
}

local handler = handlers.new({
  constants = constants,
  utils = require('core.utils'),
  health = health,
  nodes = nodes,
  comms = function() return { get_peers = function() return {} end } end,
  sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end },
  sync_rt_node = function() end,
  mark_rt_sync_dirty = function() end,
  add_alarm = function() end,
  master_time_label = function() return '12:00:00' end,
  log = function() end
})

handler.update_node({
  type = constants.message_types.STATUS,
  sender_id = 'ENERGY-1',
  node_id = 'node-49',
  role = constants.roles.ENERGY_NODE,
  proto_ver = constants.proto_ver,
  payload = { status = constants.status_levels.OK }
})

if nodes['ENERGY-1'] ~= nil then
  error('expected legacy sender_id entry to be remapped away')
end
if not nodes['node-49'] then
  error('expected canonical node entry to exist')
end
if nodes['node-49'].managed ~= true then
  error('expected canonical node to be managed after status')
end

print('master_message_handler_node_id_canonicalization_test.lua: ok')
