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
  -- Physical setup:
  --   ME Bridge ──export──► fuel_chest ──Mekanism pipes──► Reactor solid injector
  --   ME Bridge ◄──import── waste_chest ◄─Mekanism pipes── Reactor waste output
  --   (or AE2 Import Bus handles waste_chest → ME automatically without CC)
  --
  -- Set enabled=true to activate. Mekanism pipes/transporters handle the
  -- chest ↔ reactor movement; CC only talks to the ME Bridge and the chests.
  DEFAULT_LOGISTICS = {
    enabled             = false,   -- Must be explicitly enabled.
    interval            = 10,      -- Seconds between routing cycles.
    discovery_interval  = 60,      -- Seconds between peripheral re-discovery.
    max_per_cycle       = 64,      -- Max items to move per cycle per source.
    --
    -- sources: ME Bridge (fuel) + waste output chest.
    --   { name = "me_bridge",     tag = "me" }              -- ME system  (fuel comes from here)
    --   { name = "waste_chest_0", tag = "reactor_output" }  -- chest where reactor drops waste
    sources             = {},
    --
    -- destinations: fuel input chest + ME Bridge (for waste return).
    --   { name = "fuel_chest_0",  tag = "reactor_injector" } -- chest Mekanism picks fuel from
    --   { name = "me_bridge",     tag = "me" }               -- ME system  (waste goes back here)
    -- NOTE: if you use AE2 Import Bus for waste return, omit the me_bridge destination.
    destinations        = {},
    --
    -- routes: optional overrides (built-in covers all ATM10/ER2 items).
    -- { match = "bigreactors:yellorium_ingot", from = "me", to = "reactor_injector",
    --   min_in_me = 64,    -- only export if ME has more than this many
    --   max_in_chest = 128 -- stop exporting if chest already has this many
    -- }
    routes              = {},
  }
}

local CURRENT_VERSION = 2

return {
  version = CURRENT_VERSION,
  role = CONFIG.DEFAULT_ROLE,
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  reset_log_on_start = CONFIG.DEFAULT_RESET_LOG_ON_START,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  storage_bus = CONFIG.DEFAULT_STORAGE_BUS,
  target = CONFIG.DEFAULT_TARGET,
  minimum_reserve = CONFIG.DEFAULT_MINIMUM_RESERVE,
  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
  discovery_interval = CONFIG.DEFAULT_DISCOVERY_INTERVAL,
  status_interval = CONFIG.DEFAULT_STATUS_INTERVAL,
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
  rails     = CONFIG.DEFAULT_RAILS,
  logistics = CONFIG.DEFAULT_LOGISTICS
}
