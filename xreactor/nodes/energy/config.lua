-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "ENERGY-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "ENERGY-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = "right", -- Default wireless modem side.
  DEFAULT_MATRIX = nil, -- Optional induction matrix peripheral name (legacy override).
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
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_DEBUG_LOGGING = false -- Enable debug logging to /xreactor/logs/energy.log.
}

return {
  role = CONFIG.DEFAULT_ROLE,
  node_id = CONFIG.DEFAULT_NODE_ID,
  debug_logging = CONFIG.DEFAULT_DEBUG_LOGGING,
  wireless_modem = CONFIG.DEFAULT_WIRELESS_MODEM,
  matrix = CONFIG.DEFAULT_MATRIX,
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
  channels = {
    control = CONFIG.DEFAULT_CONTROL_CHANNEL,
    status = CONFIG.DEFAULT_STATUS_CHANNEL
  }
}
