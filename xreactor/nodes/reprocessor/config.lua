-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "REPROCESSOR-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "REPROC-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = "right", -- Default wireless modem side.
  DEFAULT_BUFFERS = { "chemical_tank_0" }, -- Default buffer peripheral names.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/reprocessor.log.
}

return {
  role = CONFIG.DEFAULT_ROLE,
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  buffers = CONFIG.DEFAULT_BUFFERS,
  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
