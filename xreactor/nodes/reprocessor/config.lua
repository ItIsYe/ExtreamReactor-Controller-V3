-- CONFIG
local CONFIG = {
  DEFAULT_NODE_ID = "REPROC-1", -- Default node_id used if none is set.
  DEFAULT_BUFFERS = { "chemical_tank_0" }, -- Default buffer peripheral names.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/reprocessor.log.
}

return {
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  buffers = CONFIG.DEFAULT_BUFFERS,
  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
