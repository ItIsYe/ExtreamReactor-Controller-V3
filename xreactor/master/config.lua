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
  DEFAULT_ALERT_EVAL_INTERVAL = 1.0, -- Seconds between alert evaluations.
  DEFAULT_ALERT_HISTORY_SIZE = 200, -- Max alert entries stored in history.
  DEFAULT_ALERT_INFO_TTL = 20, -- Seconds before INFO alerts expire.
  DEFAULT_ALERT_DEBOUNCE_S = 2.0, -- Minimum seconds before raising alerts.
  DEFAULT_ALERT_CLEAR_S = 3.0, -- Minimum seconds before clearing alerts.
  DEFAULT_ALERT_COOLDOWN_S = 6.0, -- Seconds between repeated alert updates.
  DEFAULT_COMMS_DOWN_CRIT_SECS = 12, -- Seconds before comms-down alert is raised.
  DEFAULT_ENERGY_WARN_PCT = 25, -- Warn when total energy percent below this.
  DEFAULT_ENERGY_CRIT_PCT = 15, -- Critical when total energy percent below this.
  DEFAULT_MATRIX_WARN_FULL_PCT = 90, -- Warn when any matrix percent exceeds this.
  DEFAULT_RPM_WARN_LOW = 800, -- Warn when turbine RPM below sustained threshold.
  DEFAULT_RPM_CRIT_HIGH = 1800, -- Critical when turbine RPM exceeds this.
  DEFAULT_ROD_STUCK_SECS = 20, -- Seconds rods must be unchanged before alerting.
  DEFAULT_STEAM_DEFICIT_PCT = 0.9, -- Steam production ratio considered deficit.
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
  alert_eval_interval = CONFIG.DEFAULT_ALERT_EVAL_INTERVAL,
  alert_history_size = CONFIG.DEFAULT_ALERT_HISTORY_SIZE,
  alert_info_ttl = CONFIG.DEFAULT_ALERT_INFO_TTL,
  alert_debounce_s = CONFIG.DEFAULT_ALERT_DEBOUNCE_S,
  alert_clear_s = CONFIG.DEFAULT_ALERT_CLEAR_S,
  alert_cooldown_s = CONFIG.DEFAULT_ALERT_COOLDOWN_S,
  comms_down_crit_secs = CONFIG.DEFAULT_COMMS_DOWN_CRIT_SECS,
  energy_warn_pct = CONFIG.DEFAULT_ENERGY_WARN_PCT,
  energy_crit_pct = CONFIG.DEFAULT_ENERGY_CRIT_PCT,
  matrix_warn_full_pct = CONFIG.DEFAULT_MATRIX_WARN_FULL_PCT,
  rpm_warn_low = CONFIG.DEFAULT_RPM_WARN_LOW,
  rpm_crit_high = CONFIG.DEFAULT_RPM_CRIT_HIGH,
  rod_stuck_secs = CONFIG.DEFAULT_ROD_STUCK_SECS,
  steam_deficit_pct = CONFIG.DEFAULT_STEAM_DEFICIT_PCT,
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
