package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local handlers = require('master.message_handlers')
local rt_sync = require('master.rt_sync')
local health = require('core.health')

local nodes = {
  ['RT-1'] = {
    id = 'RT-1',
    role = constants.roles.RT_NODE,
    mode = 'MASTER',
    status = constants.status_levels.OK,
    state = constants.node_states.RUNNING,
    output = 200
  }
}

local pending = {}
local sends = 0
local sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end, active = nil }

local function mark_rt_sync_dirty(node, reason)
  local id = node.id
  local slot = pending[id]
  if not slot then
    pending[id] = { node = node, reasons = { [tostring(reason)] = true } }
    return
  end
  slot.node = node
  slot.reasons[tostring(reason)] = true
end

local function flush_once()
  for id, item in pairs(pending) do
    local reason_list = {}
    for reason, enabled in pairs(item.reasons) do
      if enabled then reason_list[#reason_list + 1] = reason end
    end
    table.sort(reason_list)
    rt_sync.sync_rt_node({
      comms = {
        send_command = function(_, _, _)
          sends = sends + 1
        end
      },
      config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
      nodes = nodes,
      power_target = 1000,
      rt_global_off = false,
      trigger = 'coalesced:' .. table.concat(reason_list, ','),
      log = function() end
    }, item.node)
    pending[id] = nil
  end
end

local handler = handlers.new({
  constants = constants,
  utils = require('core.utils'),
  health = health,
  nodes = nodes,
  comms = function() return { get_peers = function() return {} end } end,
  sequencer = sequencer,
  mark_rt_sync_dirty = mark_rt_sync_dirty,
  add_alarm = function() end,
  master_time_label = function() return '12:00:00' end,
  log = function() end
})

handler.update_node({ type = constants.message_types.HELLO, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = {} })
handler.update_node({ type = constants.message_types.HEARTBEAT, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { state = constants.node_states.RUNNING } })
handler.update_node({ type = constants.message_types.STATUS, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { status = constants.status_levels.OK, mode = 'MASTER', health = { status = constants.status_levels.OK, reasons = {} } } })

flush_once()
if sends ~= 1 then
  error('expected exactly one coalesced send for hello+heartbeat+status, got ' .. tostring(sends))
end

flush_once()
if sends ~= 1 then
  error('flush without new dirty events must not send additional commands')
end

print('master_rt_sync_coalesced_semantics_test.lua: ok')
