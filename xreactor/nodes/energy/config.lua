-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "ENERGY-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "ENERGY-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = "right", -- Default wireless modem side.
  DEFAULT_MATRIX = nil, -- Optional induction matrix peripheral name (legacy override).
  DEFAULT_MATRIX_NAMES = {}, -- Optional list of induction matrix peripheral names (legacy override).
  DEFAULT_MATRIX_ALIASES = {}, -- Optional mapping of peripheral name -> display label.
  DEFAULT_CUBES = {}, -- Optional list of energy cube names (legacy override).
  DEFAULT_SCAN_INTERVAL = 15, -- Seconds between discovery scans.
  DEFAULT_UI_REFRESH_INTERVAL = 1.0, -- Seconds between monitor UI refreshes.
  DEFAULT_UI_SCALE = 0.5, -- Monitor text scale for ENERGY node UI.
  DEFAULT_MONITOR_PREFERRED = nil, -- Optional monitor name to pin.
  DEFAULT_MONITOR_STRATEGY = "largest", -- "largest" or "first".
  DEFAULT_STORAGE_INCLUDE = nil, -- Optional allow-list of storage peripheral names.
  DEFAULT_STORAGE_EXCLUDE = {}, -- Optional deny-list of storage peripheral names.
  DEFAULT_STORAGE_PREFER = {}, -- Optional list of names to prioritize.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
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
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/energy.log.
}

return {
  role = CONFIG.DEFAULT_ROLE,
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  matrix = CONFIG.DEFAULT_MATRIX,
  matrix_names = CONFIG.DEFAULT_MATRIX_NAMES,
  matrix_aliases = CONFIG.DEFAULT_MATRIX_ALIASES,
  cubes = CONFIG.DEFAULT_CUBES,
  scan_interval = CONFIG.DEFAULT_SCAN_INTERVAL,
  ui_refresh_interval = CONFIG.DEFAULT_UI_REFRESH_INTERVAL,
  ui_scale = CONFIG.DEFAULT_UI_SCALE,
  monitor = {
    preferred_name = CONFIG.DEFAULT_MONITOR_PREFERRED,
    strategy = CONFIG.DEFAULT_MONITOR_STRATEGY
  },
  storage_filters = {
    include_names = CONFIG.DEFAULT_STORAGE_INCLUDE,
    exclude_names = CONFIG.DEFAULT_STORAGE_EXCLUDE,
    prefer_names = CONFIG.DEFAULT_STORAGE_PREFER
  },
  heartbeat_interval = CONFIG.DEFAULT_HEARTBEAT_INTERVAL,
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
    peer_timeout_s = CONFIG.DEFAULT_COMMS_PEER_TIMEOUT
  }
}
