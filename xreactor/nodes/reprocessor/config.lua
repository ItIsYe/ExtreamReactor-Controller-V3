-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "REPROCESSOR-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "REPROC-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = nil, -- Autodetect wireless modem unless explicitly configured.
  DEFAULT_BUFFERS = { "chemical_tank_0" }, -- Default buffer peripheral names.
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
  DEFAULT_DEBUG_LOGGING = false, -- Enable debug logging to /xreactor_logs/reprocessor.log.
  DEFAULT_RESET_LOG_ON_START = true, -- Truncate runtime log at startup to keep disk usage bounded.
  -- Logistics routing for the REPROCESSOR node.
  --
  -- Physical setup:
  -- Logistics routing for the REPROCESSOR node.
  --
  -- Physical setup:
  --   ONE shared Mekanism pipe network per item type.
  --   Mekanism distributes waste to ALL connected reprocessors automatically.
  --
  --   ME Bridge ──Cyanite──► [waste_in_chest] ──Mekanism waste pipe──► Reprocessor A
  --                                                                └──► Reprocessor B
  --
  --   [fuel_out_chest] ◄──Mekanism output pipe──── Reprocessor A
  --                    ◄─────────────────────────  Reprocessor B
  --   ME Bridge ◄────── fuel_out_chest
  --
  -- One chest per ITEM TYPE — not per reprocessor.
  DEFAULT_LOGISTICS = {
    enabled            = false,
    interval           = 10,
    discovery_interval = 60,
    me_bridge          = "me_bridge",
    --
    -- supply: one entry per ITEM TYPE.
    -- 'chest' can be a standard chest OR a Mekanism Logistical Transporter name
    -- (visible via Wired Modem as "mekanism:ultimate_logistical_transporter_N").
    -- For transporters: add transporter=true — fill check is skipped since items
    -- transit immediately; CC exports a fixed batch (max) each cycle.
    -- For chests: CC exports when level drops below 'min', fills up to 'max'.
    --
    -- Chest example:
    --   { chest = "chest_0", item = "bigreactors:yellorium_ingot",
    --      label = "Yellorium", min = 64, max = 256 }
    -- Transporter example (Wired Modem required):
    --   { chest = "mekanism:ultimate_logistical_transporter_0",
    --      item  = "bigreactors:yellorium_ingot",
    --      label = "Yellorium transporter", max = 64, transporter = true }
    supply  = {},
    --
    -- collect: chests or transporters to drain INTO ME.
    -- Transporter: 'list()' shows in-transit items; importItemFromPeripheral
    -- pulls whatever Mekanism has routed into/through the transporter.
    -- Skip entries if AE2 Import Bus handles the return trip automatically.
    -- { chest = "waste_chest_0", label = "Waste collection" }
    -- { chest = "mekanism:ultimate_logistical_transporter_1", label = "Waste transporter" }
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
  buffers = CONFIG.DEFAULT_BUFFERS,
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
