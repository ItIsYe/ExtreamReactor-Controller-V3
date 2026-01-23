-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "RT-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "RT-1", -- Default node_id used if none is set.
  DEFAULT_REACTORS = { "BigReactors-Reactor_6" }, -- Default reactor peripheral names.
  DEFAULT_TURBINES = { "BigReactors-Turbine_327", "BigReactors-Turbine_426" }, -- Default turbine peripheral names.
  DEFAULT_MODEM = "right", -- Default modem side or peripheral name.
  DEFAULT_WIRELESS_MODEM = "right", -- Default wireless modem side.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
  DEFAULT_SCAN_INTERVAL = 10, -- Seconds between discovery scans.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/rt.log.
}

return {
  role = CONFIG.DEFAULT_ROLE,
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,

  reactors = CONFIG.DEFAULT_REACTORS,

  turbines = CONFIG.DEFAULT_TURBINES,

  modem = CONFIG.DEFAULT_MODEM,

  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,

  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
  scan_interval = CONFIG.DEFAULT_SCAN_INTERVAL,

  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
