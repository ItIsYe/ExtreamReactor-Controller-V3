package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

local constants = require('shared.constants')
local health = require('core.health')
local handlers = require('master.message_handlers')

-- node.status uses constants.status_levels (OK/LIMITED/WARNING/EMERGENCY/
-- OFFLINE/MANUAL), a separate enum from node.health.status's own
-- OK/DEGRADED/DOWN -- assign_node_status_from_health() translates between
-- them (health.status.DEGRADED -> constants.status_levels.WARNING), so a
-- degraded node's node.status is WARNING, not the raw health.status value.
local nodes = {
  ["ENERGY-1"] = {
    id = "ENERGY-1", role = constants.roles.ENERGY_NODE, status = constants.status_levels.WARNING,
    health = { status = health.status.DEGRADED, reasons = { [health.reasons.COMMS_DOWN] = true } }
  }
}

local handler = handlers.new({
  constants = constants,
  utils = { normalize_node_id = function(v) return v end, merge = function(dst, src) for k,v in pairs(src) do dst[k]=v end return dst end },
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

handler.update_node({ type = constants.message_types.HEARTBEAT, sender_id='ENERGY-1', node_id='ENERGY-1', role=constants.roles.ENERGY_NODE, payload={state='RUNNING'} })
if nodes['ENERGY-1'].status ~= constants.status_levels.WARNING then error('heartbeat must not blindly force degraded node to OK without healthy payload') end

handler.update_node({ type = constants.message_types.STATUS, sender_id='ENERGY-1', node_id='ENERGY-1', role=constants.roles.ENERGY_NODE, payload={ health={ status=health.status.OK, reasons={} } } })
if nodes['ENERGY-1'].status ~= constants.status_levels.OK then error('healthy STATUS payload must clear degraded status') end

print('master_status_recovery_semantics_test.lua: ok')
