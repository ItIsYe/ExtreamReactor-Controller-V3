-- CONFIG
local CONFIG = {
  DEFAULT_NODE_ID = "ENERGY-1", -- Default node_id used if none is set.
  DEFAULT_MATRIX = "inductionPort_0", -- Default induction matrix peripheral name.
  DEFAULT_CUBES = { "inductionPort_0" }, -- Default list of energy cube names.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/energy.log.
}

return {
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  matrix = CONFIG.DEFAULT_MATRIX,
  cubes = CONFIG.DEFAULT_CUBES,
  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
