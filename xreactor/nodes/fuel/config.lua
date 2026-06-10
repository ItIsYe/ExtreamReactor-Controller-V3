-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "FUEL-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "FUEL-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = nil, -- Autodetect wireless modem unless explicitly configured.
  DEFAULT_STORAGE_BUS = "meBridge_0", -- Default storage bus peripheral name.
  DEFAULT_TARGET = 2000, -- Default fuel reserve target.
  DEFAULT_MINIMUM_RESERVE = 2000, -- Minimum reserve used for safety.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
  DEFAULT_DISCOVERY_INTERVAL = 15, -- Seconds between discovery rescans.
  DEFAULT_STATUS_INTERVAL = 5, -- Seconds between status payloads.
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
  -- Control rails tuning (shared defaults for RT nodes).
  DEFAULT_RAILS = {
    ramp_profiles = {
      NORMAL = { up = 1.0, down = 1.0 },
      SLOW = { up = 0.5, down = 0.5 },
      FAST = { up = 1.5, down = 1.5 }
    },
    turbine_flow = {
      deadband_up = 20,
      deadband_down = 20,
      hysteresis_up = 10,
      hysteresis_down = 10,
      max_step_up = 50,
      max_step_down = 50,
      cooldown_s = 1.0,
      min = 200,
      max = 1900,
      ema_alpha = 0.2
    },
    reactor_rods = {
      deadband_up = 5000,
      deadband_down = 5000,
      hysteresis_up = 500,
      hysteresis_down = 500,
      max_step_up = 5,
      max_step_down = 5,
      cooldown_s = 1.5,
      min = 0,
      max = 98,
      ema_alpha = 0.25
    },
    coil = {
      engage_rpm = 850,
      disengage_rpm = 750,
      cooldown_s = 1.0,
      ema_alpha = 0.2
    }
  },
  DEFAULT_DEBUG_LOGGING = false, -- Enable debug logging to /xreactor_logs/fuel.log.
  DEFAULT_RESET_LOG_ON_START = true, -- Truncate runtime log at startup to keep disk usage bounded.
  -- Logistics routing for the FUEL node.
  --
  -- Each reactor has its OWN entry. The FUEL node reads fuel levels DIRECTLY
  -- from the reactor's ER2 Computer Port via Wired Modem and only exports
  -- fuel to the reactor that is actually requesting it.
  --
  -- Hardware (FUEL computer must have):
  --   Wired Modem → ER2 Reactor Computer Ports + dedicated inlet transporter/chest
  --   Wireless Modem → MASTER communication
  --
  DEFAULT_LOGISTICS = {
    enabled            = false,
    interval           = 5,       -- seconds between supply checks (short for responsiveness)
    discovery_interval = 60,
    me_bridge          = "me_bridge",   -- AP 1.21.1+; "meBridge" on older
    --
    -- reactors: one entry per reactor.
    --   reactor_port  = peripheral name of the ER2 Reactor Computer Port (Wired Modem)
    --   inlet         = where to deliver fuel (transporter or chest — must be dedicated
    --                   to THIS reactor; no shared pipes for targeted delivery)
    --   item          = fuel item name
    --   request_below = fuel ratio below which reactor requests resupply (0.0–1.0)
    --   fill_amount   = how many items to export per resupply event
    --   min_in_me     = minimum ME stock to maintain (never export below this)
    --
    -- Example (two reactors on Wired Modem network):
    -- { name          = "Reaktor A",
    --   reactor_port  = "BigReactors-Reactor_0",
    --   inlet         = "mekanism:ultimate_logistical_transporter_0",
    --   item          = "bigreactors:yellorium_ingot",
    --   request_below = 0.25,
    --   fill_amount   = 64,
    --   min_in_me     = 128 },
    -- { name          = "Reaktor B",
    --   reactor_port  = "BigReactors-Reactor_1",
    --   inlet         = "mekanism:ultimate_logistical_transporter_1",
    --   item          = "bigreactors:yellorium_ingot",
    --   request_below = 0.25,
    --   fill_amount   = 64,
    --   min_in_me     = 128 },
    reactors           = {},
    --
    -- waste: peripheral(s) where reactor waste arrives — CC drains into ME.
    -- { name = "Reaktor A Waste", outlet = "mekanism:ultimate_logistical_transporter_2" },
    waste              = {},
  }
  rails     = CONFIG.DEFAULT_RAILS,
  logistics = CONFIG.DEFAULT_LOGISTICS
}
