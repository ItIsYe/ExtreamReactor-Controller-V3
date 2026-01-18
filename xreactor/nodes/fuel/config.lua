-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "FUEL-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "FUEL-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = "right", -- Default wireless modem side.
  DEFAULT_STORAGE_BUS = "meBridge_0", -- Default storage bus peripheral name.
  DEFAULT_TARGET = 2000, -- Default fuel reserve target.
  DEFAULT_MINIMUM_RESERVE = 2000, -- Minimum reserve used for safety.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/fuel.log.
}

return {
  role = CONFIG.DEFAULT_ROLE,
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  storage_bus = CONFIG.DEFAULT_STORAGE_BUS,
  target = CONFIG.DEFAULT_TARGET,
  minimum_reserve = CONFIG.DEFAULT_MINIMUM_RESERVE,
  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
