-- CONFIG
local CONFIG = {
  DEFAULT_WIRELESS_MODEM = "right", -- Default wireless modem side.
  DEFAULT_WIRED_MODEM = "left", -- Default wired modem side for monitors.
  DEFAULT_MONITORS = { "back" }, -- Default monitor list for UI.
  DEFAULT_HEARTBEAT_INTERVAL = 5, -- Seconds between status heartbeats.
  DEFAULT_STATUS_INTERVAL = 5, -- Seconds between status broadcasts.
  DEFAULT_STARTUP_RAMP = "NORMAL", -- Startup ramp profile name.
  DEFAULT_RT_MODE = "MASTER", -- Default mode for RT nodes.
  DEFAULT_TARGET_RPM = 900, -- Default RT target RPM.
  DEFAULT_COMMS_CHANNEL = 6500, -- Comms control channel.
  DEFAULT_STATUS_CHANNEL = 6501, -- Comms status channel.
  DEFAULT_COMMS_ACK_TIMEOUT = 3.0, -- Seconds before retrying a command.
  DEFAULT_COMMS_MAX_RETRIES = 4, -- Maximum retries per message.
  DEFAULT_COMMS_BACKOFF_BASE = 0.6, -- Base backoff seconds.
  DEFAULT_COMMS_BACKOFF_CAP = 6.0, -- Max backoff seconds.
  DEFAULT_COMMS_DEDUPE_TTL = 30, -- Seconds to keep dedupe entries.
  DEFAULT_COMMS_DEDUPE_LIMIT = 200, -- Max dedupe entries per peer.
  DEFAULT_COMMS_PEER_TIMEOUT = 12.0, -- Seconds before marking peer down.
  DEFAULT_COMMS_QUEUE_LIMIT = 200, -- Max queued outbound messages.
  DEFAULT_COMMS_DROP_SIMULATION = 0, -- Drop rate (0-1) for testing comms.
  -- Control rails tuning (shared defaults for RT nodes).
  DEFAULT_RAILS = {
    ramp_profiles = {
      NORMAL = { up = 1.0, down = 1.0 },
      SLOW = { up = 0.5, down = 0.5 },
      FAST = { up = 1.5, down = 1.5 }
    },
    turbine_flow = {
      deadband_up = 20, -- RPM deadband before increasing flow.
      deadband_down = 20, -- RPM deadband before decreasing flow.
      hysteresis_up = 10, -- RPM hysteresis (up).
      hysteresis_down = 10, -- RPM hysteresis (down).
      max_step_up = 50, -- Max flow increase per tick.
      max_step_down = 50, -- Max flow decrease per tick.
      cooldown_s = 1.0, -- Minimum seconds between flow changes.
      min = 200, -- Flow clamp minimum.
      max = 1900, -- Flow clamp maximum.
      ema_alpha = 0.2 -- RPM smoothing alpha.
    },
    reactor_rods = {
      deadband_up = 5000, -- Steam reserve deadband before inserting rods.
      deadband_down = 5000, -- Steam deficit deadband before withdrawing rods.
      hysteresis_up = 500, -- Steam hysteresis (insert).
      hysteresis_down = 500, -- Steam hysteresis (withdraw).
      max_step_up = 5, -- Max rod insert step.
      max_step_down = 5, -- Max rod withdraw step.
      cooldown_s = 1.5, -- Minimum seconds between rod changes.
      min = 0, -- Rod clamp minimum.
      max = 98, -- Rod clamp maximum.
      ema_alpha = 0.25 -- Steam margin smoothing alpha.
    },
    coil = {
      engage_rpm = 850, -- Coil engage threshold.
      disengage_rpm = 750, -- Coil disengage threshold.
      cooldown_s = 1.0, -- Minimum seconds between coil changes.
      ema_alpha = 0.2 -- RPM smoothing alpha.
    }
  },
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/master.log.
}

local constants = require("shared.constants")

return {
  role = constants.roles.MASTER,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  wired_modem = CONFIG.DEFAULT_WIRED_MODEM,
  monitors = CONFIG.DEFAULT_MONITORS,
  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
  status_interval = CONFIG.DEFAULT_STATUS_INTERVAL,
  startup_ramp = CONFIG.DEFAULT_STARTUP_RAMP,
  rt_default_mode = CONFIG.DEFAULT_RT_MODE,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  channels = {
    control = CONFIG.DEFAULT_COMMS_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  },
  comms = {
    ack_timeout_s = CONFIG.DEFAULT_COMMS_ACK_TIMEOUT,
    max_retries = CONFIG.DEFAULT_COMMS_MAX_RETRIES,
    backoff_base_s = CONFIG.DEFAULT_COMMS_BACKOFF_BASE,
    backoff_cap_s = CONFIG.DEFAULT_COMMS_BACKOFF_CAP,
    dedupe_ttl_s = CONFIG.DEFAULT_COMMS_DEDUPE_TTL,
    dedupe_limit = CONFIG.DEFAULT_COMMS_DEDUPE_LIMIT,
    peer_timeout_s = CONFIG.DEFAULT_COMMS_PEER_TIMEOUT,
    queue_limit = CONFIG.DEFAULT_COMMS_QUEUE_LIMIT,
    drop_simulation = CONFIG.DEFAULT_COMMS_DROP_SIMULATION
  },
  rt_setpoints = {
    target_rpm = CONFIG.DEFAULT_TARGET_RPM,
    enable_reactors = true,
    enable_turbines = true
  },
  rails = CONFIG.DEFAULT_RAILS,
  nodes = {
    [constants.roles.RT_NODE] = {},
    [constants.roles.ENERGY_NODE] = {},
    [constants.roles.FUEL_NODE] = {},
    [constants.roles.WATER_NODE] = {},
    [constants.roles.REPROCESSOR_NODE] = {}
  }
}
