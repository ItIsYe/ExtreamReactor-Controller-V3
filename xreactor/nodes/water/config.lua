-- CONFIG
local CONFIG = {
  DEFAULT_NODE_ID = "WATER-1", -- Default node_id used if none is set.
  DEFAULT_LOOP_TANKS = { "dynamicTank_0" }, -- Default tank peripheral names.
  DEFAULT_TARGET_VOLUME = 200000, -- Desired tank volume.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/water.log.
}

return {
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  loop_tanks = CONFIG.DEFAULT_LOOP_TANKS,
  target_volume = CONFIG.DEFAULT_TARGET_VOLUME,
  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
