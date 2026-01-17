-- CONFIG
local CONFIG = {
  DEFAULT_WIRELESS_MODEM = "right", -- Default wireless modem side.
  DEFAULT_WIRED_MODEM = "left", -- Default wired modem side for monitors.
  DEFAULT_MONITORS = { "back" }, -- Default monitor list for UI.
  DEFAULT_HEARTBEAT_INTERVAL = 5, -- Seconds between status heartbeats.
  DEFAULT_STARTUP_RAMP = "NORMAL", -- Startup ramp profile name.
  DEFAULT_RT_MODE = "MASTER", -- Default mode for RT nodes.
  DEFAULT_TARGET_RPM = 900, -- Default RT target RPM.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/master.log.
}

local constants = require("shared.constants")

return {
  role = constants.roles.MASTER,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  wired_modem = CONFIG.DEFAULT_WIRED_MODEM,
  monitors = CONFIG.DEFAULT_MONITORS,
  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
  startup_ramp = CONFIG.DEFAULT_STARTUP_RAMP,
  rt_default_mode = CONFIG.DEFAULT_RT_MODE,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  rt_setpoints = {
    target_rpm = CONFIG.DEFAULT_TARGET_RPM,
    enable_reactors = true,
    enable_turbines = true
  },
  nodes = {
    [constants.roles.RT_NODE] = {},
    [constants.roles.ENERGY_NODE] = {},
    [constants.roles.FUEL_NODE] = {},
    [constants.roles.WATER_NODE] = {},
    [constants.roles.REPROCESSOR_NODE] = {}
  }
}
