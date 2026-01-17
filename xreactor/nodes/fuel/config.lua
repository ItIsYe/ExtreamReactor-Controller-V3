-- CONFIG
local CONFIG = {
  DEFAULT_NODE_ID = "FUEL-1", -- Default node_id used if none is set.
  DEFAULT_STORAGE_BUS = "meBridge_0", -- Default storage bus peripheral name.
  DEFAULT_TARGET = 2000, -- Default fuel reserve target.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/fuel.log.
}

return {
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  storage_bus = CONFIG.DEFAULT_STORAGE_BUS,
  target = CONFIG.DEFAULT_TARGET,
  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
