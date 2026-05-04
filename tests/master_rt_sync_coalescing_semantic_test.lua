package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local coalescer_lib = require('master.rt_sync_coalescer')
local handlers = require('master.message_handlers')
local health = require('core.health')
local rt_sync = require('master.rt_sync')
local utils = require('core.utils')

local sends = 0
local nodes = {
  ['RT-1'] = { id = 'RT-1', role = constants.roles.RT_NODE, mode = 'MASTER', status = constants.status_levels.OK, state = constants.node_states.RUNNING, output = 500 }
}

local coalescer = coalescer_lib.new({
  constants = constants,
  utils = utils,
  batch_window_ms = 250,
  sync_rt_node = function(node, reason)
    rt_sync.sync_rt_node({
      comms = { send_command = function() sends = sends + 1 end },
      config = { rt_setpoints = { target_rpm = 900, steam_target = 4000, enable_reactors = true, enable_turbines = true, power_per_node_capacity = 3000 } },
      nodes = nodes,
      power_target = 1000,
      rt_global_off = false,
      trigger = reason,
      log = function() end
    }, node)
  end,
  log = function() end
})

local handler = handlers.new({
  constants = constants,
  utils = utils,
  health = health,
  nodes = nodes,
  comms = function() return { get_peers = function() return {} end } end,
  sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end, active = nil },
  mark_rt_sync_dirty = function(node, reason) coalescer.mark_dirty(node, reason) end,
  add_alarm = function() end,
  master_time_label = function() return '12:00:00' end,
  log = function() end
})

handler.update_node({ type = constants.message_types.HELLO, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = {} })
handler.update_node({ type = constants.message_types.HEARTBEAT, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { state = constants.node_states.RUNNING } })
handler.update_node({ type = constants.message_types.STATUS, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { status = constants.status_levels.OK, mode = 'MASTER', health = { status = constants.status_levels.OK, reasons = {} } } })

coalescer.flush({ force = true })
if sends ~= 1 then error('hello+heartbeat+status burst must produce exactly one coalesced sync command') end
if coalescer.size() ~= 0 then error('queue must be empty after flush') end

coalescer.flush({ force = true })
if sends ~= 1 then error('second flush without new dirty must not add commands') end


handler.update_node({ type = constants.message_types.HEARTBEAT, sender_id = 'rt-1', node_id = 'rt-1', role = constants.roles.RT_NODE, payload = { state = constants.node_states.RUNNING } })
coalescer.flush()
if sends ~= 1 then error('flush without force inside batch window must not send immediately') end
if coalescer.size() ~= 1 then error('pending queue must retain node until batch window or force flush') end
coalescer.flush({ force = true })
if sends ~= 2 then error('forced flush must send exactly one command for pending node') end
if coalescer.size() ~= 0 then error('queue must be empty after forced flush of pending node') end

print('master_rt_sync_coalescing_semantic_test.lua: ok')
