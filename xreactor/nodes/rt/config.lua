-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "RT-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "RT-1", -- Default node_id used if none is set.
  DEFAULT_REACTORS = { "BigReactors-Reactor_6" }, -- Default reactor peripheral names.
  DEFAULT_TURBINES = { "BigReactors-Turbine_327", "BigReactors-Turbine_426" }, -- Default turbine peripheral names.
  DEFAULT_MODEM = "right", -- Default modem side or peripheral name.
  DEFAULT_WIRELESS_MODEM = "right", -- Default wireless modem side.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
  DEFAULT_STATUS_INTERVAL = 5, -- Seconds between status payloads.
  DEFAULT_SCAN_INTERVAL = 10, -- Seconds between discovery scans.
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
  status_interval = CONFIG.DEFAULT_STATUS_INTERVAL,
  scan_interval = CONFIG.DEFAULT_SCAN_INTERVAL,

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
  rails = CONFIG.DEFAULT_RAILS
}
