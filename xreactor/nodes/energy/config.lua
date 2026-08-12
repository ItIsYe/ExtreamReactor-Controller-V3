-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "ENERGY-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "ENERGY-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = nil, -- Autodetect wireless modem unless explicitly configured.
  DEFAULT_MATRIX = nil, -- Optional induction matrix peripheral name (legacy override).
  DEFAULT_MATRIX_NAMES = {}, -- Optional list of induction matrix peripheral names (legacy override).
  DEFAULT_MATRIX_ALIASES = {}, -- Optional mapping of peripheral name -> display label.
  DEFAULT_CUBES = {}, -- Optional list of energy cube names.
  DEFAULT_SCAN_INTERVAL = 15, -- Seconds between discovery scans.

  -- Matrix reads can be very slow on large Mekanism matrices. Keep every sampling
  -- tick short so heartbeats/comms stay responsive; freshness is preferred over
  -- long blocking bursts.
  DEFAULT_MATRIX_METRIC_POLL_INTERVAL = 12.0,
  DEFAULT_MATRIX_METRIC_CALL_BUDGET = 1,
  DEFAULT_MATRIX_METRIC_TIME_BUDGET_MS = 5000,  -- erhöht: Matrix braucht real 2.6-3.6s
  DEFAULT_MATRIX_METRIC_SLOW_CALL_MS = 150,
  DEFAULT_MATRIX_METRIC_SLOW_POLL_MULTIPLIER = 6.0,
  DEFAULT_MATRIX_METRIC_PER_MATRIX_BUDGET = 1,
  DEFAULT_MATRIX_COMPONENT_POLL_INTERVAL = 60,
  DEFAULT_MATRIX_COMPONENT_CALL_BUDGET = 1,
  DEFAULT_MATRIX_COMPONENT_TIME_BUDGET_MS = 1200,

  DEFAULT_UI_REFRESH_INTERVAL = 1.5, -- Slightly slower UI refresh to leave room for comms.
  DEFAULT_UI_SCALE = 0.5, -- Monitor text scale for the ENERGY node UI.
  DEFAULT_MONITOR_PREFERRED = nil, -- Optional monitor name to pin.
  DEFAULT_MONITOR_STRATEGY = "largest", -- "largest" or "first".
  DEFAULT_STORAGE_INCLUDE = nil, -- Optional allow-list of storage peripheral names.
  DEFAULT_STORAGE_EXCLUDE = {}, -- Optional deny-list of storage peripheral names.
  DEFAULT_STORAGE_PREFER = {}, -- Optional list of names to prioritize.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
  DEFAULT_STATUS_INTERVAL = 6, -- Slightly slower status payloads while matrix reads are expensive.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_COMMS_ACK_TIMEOUT = 4.0, -- Seconds before retrying a command.
  DEFAULT_COMMS_MAX_RETRIES = 4, -- Maximum retries per message.
  DEFAULT_COMMS_BACKOFF_BASE = 0.8, -- Base backoff seconds.
  DEFAULT_COMMS_BACKOFF_CAP = 8.0, -- Max backoff seconds.
  DEFAULT_COMMS_DEDUPE_TTL = 30, -- Seconds to keep dedupe entries.
  DEFAULT_COMMS_DEDUPE_LIMIT = 200, -- Max dedupe entries per peer.
  DEFAULT_COMMS_PEER_TIMEOUT = 45.0, -- tolerate occasional slow matrix calls without peer flapping.
  DEFAULT_COMMS_PEER_DOWN_GRACE = 10.0, -- Extra stale time before peer-down transition.
  DEFAULT_COMMS_PEER_DOWN_MIN_OBSERVATIONS = 3, -- Consecutive stale checks required before peer-down transition.
  DEFAULT_COMMS_PEER_UP_DEBOUNCE = 3.0, -- Stable visibility required before peer-up transition.
  DEFAULT_COMMS_PEER_UP_MIN_OBSERVATIONS = 3, -- Fresh peer messages required before peer-up transition.
  DEFAULT_COMMS_QUEUE_LIMIT = 200, -- Max queued outbound messages.
  DEFAULT_COMMS_DROP_SIMULATION = 0, -- Drop rate (0-1) for testing comms.
  DEFAULT_DEBUG_LOGGING = true, -- Enabled by default so ENERGY diagnostics are always available.
  DEFAULT_RESET_LOG_ON_START = true -- Truncate runtime log at startup to keep disk usage bounded.
}

local CURRENT_VERSION = 3

return {
  version = CURRENT_VERSION,
  role = CONFIG.DEFAULT_ROLE,
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  reset_log_on_start = CONFIG.DEFAULT_RESET_LOG_ON_START,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  matrix = CONFIG.DEFAULT_MATRIX,
  matrix_names = CONFIG.DEFAULT_MATRIX_NAMES,
  matrix_aliases = CONFIG.DEFAULT_MATRIX_ALIASES,
  cubes = CONFIG.DEFAULT_CUBES,
  scan_interval = CONFIG.DEFAULT_SCAN_INTERVAL,
  matrix_metric_poll_interval = CONFIG.DEFAULT_MATRIX_METRIC_POLL_INTERVAL,
  matrix_metric_call_budget = CONFIG.DEFAULT_MATRIX_METRIC_CALL_BUDGET,
  matrix_metric_time_budget_ms = CONFIG.DEFAULT_MATRIX_METRIC_TIME_BUDGET_MS,
  matrix_metric_slow_call_ms = CONFIG.DEFAULT_MATRIX_METRIC_SLOW_CALL_MS,
  matrix_metric_slow_poll_multiplier = CONFIG.DEFAULT_MATRIX_METRIC_SLOW_POLL_MULTIPLIER,
  matrix_metric_per_matrix_budget = CONFIG.DEFAULT_MATRIX_METRIC_PER_MATRIX_BUDGET,
  matrix_component_poll_interval = CONFIG.DEFAULT_MATRIX_COMPONENT_POLL_INTERVAL,
  matrix_component_call_budget = CONFIG.DEFAULT_MATRIX_COMPONENT_CALL_BUDGET,
  matrix_component_time_budget_ms = CONFIG.DEFAULT_MATRIX_COMPONENT_TIME_BUDGET_MS,
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
    peer_timeout_s = CONFIG.DEFAULT_COMMS_PEER_TIMEOUT,
    peer_down_grace_s = CONFIG.DEFAULT_COMMS_PEER_DOWN_GRACE,
    peer_down_min_observations = CONFIG.DEFAULT_COMMS_PEER_DOWN_MIN_OBSERVATIONS,
    peer_up_debounce_s = CONFIG.DEFAULT_COMMS_PEER_UP_DEBOUNCE,
    peer_up_min_observations = CONFIG.DEFAULT_COMMS_PEER_UP_MIN_OBSERVATIONS,
    queue_limit = CONFIG.DEFAULT_COMMS_QUEUE_LIMIT,
    drop_simulation = CONFIG.DEFAULT_COMMS_DROP_SIMULATION
  }
}
