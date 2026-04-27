local constants = require('shared.constants')
local health = require('core.health')
local message_handlers = require('master.message_handlers')

local nodes = {
  ["ENERGY-1"] = {
    id = "ENERGY-1",
    role = constants.roles.ENERGY_NODE,
    status = health.status.DOWN,
    offline = true,
    stale = true,
    managed = false,
    down_since = 1000,
    health = {
      status = health.status.DOWN,
      reasons = { [health.reasons.COMMS_DOWN] = true }
    }
  }
}

local handler = message_handlers.new({
  constants = constants,
  utils = {
    normalize_node_id = function(v)
      return v
    end,
    merge = function(dst, src)
      for k, value in pairs(src or {}) do
        dst[k] = value
      end
      return dst
    end
  },
  health = health,
  nodes = nodes,
  comms = function()
    return { get_peers = function() return {} end }
  end,
  sequencer = {
    enqueue = function() end,
    notify_stable = function() end,
    notify_ack = function() end
  },
  sync_rt_node = function() end,
  add_alarm = function() end,
  master_time_label = function() return "12:00:00" end,
  log = function() end
})

handler.update_node({
  type = constants.message_types.HEARTBEAT,
  src = "ENERGY-1",
  sender_id = "ENERGY-1",
  node_id = "ENERGY-1",
  role = constants.roles.ENERGY_NODE,
  payload = { state = "RUNNING" }
})

local node = nodes["ENERGY-1"]
if not node then
  error("node missing after heartbeat")
end
if node.status ~= constants.status_levels.OK then
  error("heartbeat should recover node status from DOWN to OK")
end
if node.offline or node.stale then
  error("heartbeat should clear offline/stale flags")
end
if node.down_since ~= nil then
  error("heartbeat should clear down_since")
end
if node.health and node.health.reasons and node.health.reasons[health.reasons.COMMS_DOWN] then
  error("heartbeat should clear COMMS_DOWN reason")
end

print('master_heartbeat_recovery_from_down_test.lua: ok')
