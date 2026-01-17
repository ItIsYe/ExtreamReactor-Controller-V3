-- CONFIG
local CONFIG = {
  DEFAULT_NODE_ID = "RT-1", -- Default node_id used if none is set.
  DEFAULT_REACTORS = { "BigReactors-Reactor_6" }, -- Default reactor peripheral names.
  DEFAULT_TURBINES = { "BigReactors-Turbine_327", "BigReactors-Turbine_426" }, -- Default turbine peripheral names.
  DEFAULT_MODEM = "right", -- Default modem side or peripheral name.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/rt.log.
}

return {
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,

  reactors = CONFIG.DEFAULT_REACTORS,

  turbines = CONFIG.DEFAULT_TURBINES,

  modem = CONFIG.DEFAULT_MODEM,

  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
