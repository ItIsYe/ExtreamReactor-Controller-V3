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
  -- Each reprocessor has its OWN entry. Only reprocessors with available
  -- capacity receive waste from ME. Output (processed fuel) is collected
  -- back into ME automatically.
  --
  DEFAULT_LOGISTICS = {
    enabled            = false,
    interval           = 5,
    discovery_interval = 60,
    me_bridge          = "me_bridge",
    --
    -- reprocessors: one entry per ER2 Reprocessor.
    --   reactor_port  = peripheral name of the ER2 Reprocessor Computer Port
    --   inlet         = dedicated transporter/chest for waste input
    --   outlet        = dedicated transporter/chest for processed fuel output
    --   waste_item    = item to send in (e.g. "bigreactors:cyanite_ingot")
    --   fill_amount   = how many waste items to send per cycle
    --   min_in_me     = minimum waste stock to keep in ME
    --
    -- { name         = "Reprocessor A",
    --   reactor_port = "BigReactors-Reprocessor_0",  -- if accessible
    --   inlet        = "mekanism:ultimate_logistical_transporter_2",
    --   outlet       = "mekanism:ultimate_logistical_transporter_3",
    --   waste_item   = "bigreactors:cyanite_ingot",
    --   fill_amount  = 16,
    --   min_in_me    = 32 },
    reprocessors       = {},
    --
    -- redstone_tree: pipe valve topology for targeted waste routing.
    -- Mekanism pipes must be set to "High Redstone = Interrupt".
    -- { side="right", label="Arm A", children={
    --     { side="top",    label="Reprocessor A", reactor="REPROC-1" },
    --     { side="bottom", label="Reprocessor B", reactor="REPROC-2" },
    --   }
    -- }
    redstone_tree    = {},
    valve_open_ms    = 2000,
  },
  rails     = CONFIG.DEFAULT_RAILS,
  logistics = CONFIG.DEFAULT_LOGISTICS
}
