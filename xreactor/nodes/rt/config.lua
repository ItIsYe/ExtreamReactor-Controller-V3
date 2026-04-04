-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "RT-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "RT-1", -- Default node_id used if none is set.
  DEFAULT_REACTORS = {}, -- Empty list enables auto-discovery for local reactors.
  DEFAULT_TURBINES = {}, -- Empty list enables auto-discovery for local turbines.
  DEFAULT_MODEM = nil, -- Legacy modem field; prefer autodetect unless explicitly configured.
  DEFAULT_WIRELESS_MODEM = nil, -- Autodetect wireless modem unless explicitly configured.
  DEFAULT_WIRED_MODEM = nil, -- Optional wired modem side override.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
  DEFAULT_STATUS_INTERVAL = 5, -- Seconds between status payloads.
  DEFAULT_SCAN_INTERVAL = 10, -- Seconds between discovery scans.
  DEFAULT_STARTUP_WATCHDOG_S = 60, -- Seconds before STARTUP watchdog trips.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_COMMS_ACK_TIMEOUT = 3.0, -- Seconds before retrying a command.
  DEFAULT_COMMS_MAX_RETRIES = 4, -- Maximum retries per message.
  DEFAULT_COMMS_BACKOFF_BASE = 0.6, -- Base backoff seconds.
  DEFAULT_COMMS_BACKOFF_CAP = 6.0, -- Max backoff seconds.
  DEFAULT_COMMS_DEDUPE_TTL = 30, -- Seconds to keep dedupe entries.
  DEFAULT_COMMS_DEDUPE_LIMIT = 200, -- Max dedupe entries per peer.
  DEFAULT_COMMS_PEER_TIMEOUT = 12.0, -- Seconds before marking peer down.
  DEFAULT_COMMS_QUEUE_LIMIT = 200, -- Max queued outbound messages.
  DEFAULT_COMMS_DROP_SIMULATION = 0, -- Drop rate (0-1) for testing comms.
  -- Control rails tuning (shared defaults).
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
      max_step_up = 250, -- Max flow increase per tick.
      max_step_down = 250, -- Max flow decrease per tick.
      min_step_up = 50, -- Min flow increase when adaptive stepping is active.
      min_step_down = 50, -- Min flow decrease when adaptive stepping is active.
      step_per_rpm_up = 0.5, -- Flow step gain per RPM error (up direction).
      step_per_rpm_down = 0.5, -- Flow step gain per RPM error (down direction).
      adaptive_step = true, -- Enable adaptive step sizing based on RPM error.
      cooldown_s = 0.2, -- Minimum seconds between flow changes.
      settle_timeout_s = 0.8, -- Max wait for readback confirmation before regular cooldown applies again.
      confirm_tolerance = 1, -- Allowed requested/confirmed flow delta for settle checks.
      readback_retry_cap = 3, -- Max deferred retries before control resumes normal cadence.
      readback_fast_rereads = 2, -- Immediate readback retries after write to reduce stale values.
      effective_min_samples = 3, -- Samples required before persisting detected minimum flow floor.
      target_hold_band_rpm = 30, -- Active target hold window around RPM target.
      target_trim_trigger_rpm = 6, -- Trigger for active trim corrections inside hold band.
      target_trim_hold_samples = 2, -- Required stable hold samples before entering HOLDING_TARGET_ACTIVE.
      target_trim_step_up = 50, -- Aggressive trim-up step in target band.
      target_trim_step_down = 75, -- Aggressive trim-down step in target band.
      min = 0, -- Flow clamp minimum.
      max = 2000, -- Flow clamp maximum.
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
      min = 50, -- Rod clamp minimum.
      max = 100, -- Rod clamp maximum.
      ema_alpha = 0.25 -- Steam margin smoothing alpha.
    },
    coil = {
      engage_rpm = 850, -- Coil engage threshold.
      disengage_rpm = 750, -- Coil disengage threshold.
      cooldown_s = 1.0, -- Minimum seconds between coil changes.
      ema_alpha = 0.2 -- RPM smoothing alpha.
    }
  },
  DEFAULT_DEBUG_LOGGING = true, -- Keep enabled by default for RT stabilization diagnostics.
  DEFAULT_RESET_LOG_ON_START = true -- Truncate RT runtime log at startup to keep disk usage bounded.
}

local CURRENT_VERSION = 3

return {
  version = CURRENT_VERSION,
  role = CONFIG.DEFAULT_ROLE,
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  reset_log_on_start = CONFIG.DEFAULT_RESET_LOG_ON_START,

  reactors = CONFIG.DEFAULT_REACTORS,

  turbines = CONFIG.DEFAULT_TURBINES,

  modem = CONFIG.DEFAULT_MODEM,

  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  wired_modem = CONFIG.DEFAULT_WIRED_MODEM,

  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
  status_interval = CONFIG.DEFAULT_STATUS_INTERVAL,
  scan_interval = CONFIG.DEFAULT_SCAN_INTERVAL,
  startup_watchdog_s = CONFIG.DEFAULT_STARTUP_WATCHDOG_S,

  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
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
  autonom = {
    regulator_min_rods = 0, -- Lower clamp for automatic rod regulator target (%).
    regulator_max_rods = CONFIG.DEFAULT_RAILS.reactor_rods.max, -- Upper clamp for automatic rod regulator target (%).
    min_rods = CONFIG.DEFAULT_RAILS.reactor_rods.min, -- Legacy alias; prefer regulator_min_rods.
    max_rods = CONFIG.DEFAULT_RAILS.reactor_rods.max -- Legacy alias; prefer regulator_max_rods.
  },
  rails = CONFIG.DEFAULT_RAILS
}
