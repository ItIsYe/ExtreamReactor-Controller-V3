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
  -- Logistics routing for the FUEL node.
  --
  -- Physical setup:
  --   ONE shared Mekanism pipe network per item type.
  --   Mekanism distributes items to ALL connected reactors automatically.
  --   CC only manages the ME ↔ chest interface.
  --
  --   ME Bridge ──Yellorium──► [fuel_chest_0] ──┬─ Mekanism fuel pipe ──► Reactor A
  --                                             ├─────────────────────► Reactor B
  --                                             └─────────────────────► Reactor C
  --
  --   [waste_chest_0] ◄──┬── Mekanism waste pipe ──── Reactor A
  --                      ├────────────────────────── Reactor B
  --   ME Bridge ◄──────  └────────────────────────── Reactor C
  --
  -- One chest per ITEM TYPE (not per reactor).
  -- Mekanism routing handles distribution across all reactors.
  DEFAULT_LOGISTICS = {
    enabled            = false,
    interval           = 10,      -- seconds between cycles
    discovery_interval = 60,      -- seconds between peripheral re-discovery
    me_bridge          = "me_bridge",  -- AP 1.21.1+; use "meBridge" on older versions
    --
    -- supply: one entry per FUEL TYPE.
    -- CC exports from ME when the shared chest drops below 'min'.
    -- Mekanism pipes distribute from this chest to all connected reactors.
    -- { chest = "fuel_chest_0",  item = "bigreactors:yellorium_ingot",
    --   label = "Yellorium",  min = 64,  max = 256 }
    -- { chest = "fuel_chest_1",  item = "bigreactors:blutonium_ingot",
    --   label = "Blutonium",  min = 32,  max = 128 }
    supply  = {},
    --
    -- collect: the shared waste collection chest(s).
    -- Mekanism brings all reactor waste here; CC imports it into ME.
    -- Skip if AE2 Import Bus handles waste chest → ME automatically.
    -- { chest = "waste_chest_0", label = "Reactor waste" }
    collect = {},
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
