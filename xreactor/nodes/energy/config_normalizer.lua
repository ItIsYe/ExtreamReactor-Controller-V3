local M = {}

-- Hilfsfunktionen für saubere Validierung
local function clamp_num(cfg, key, min_val, max_val, default, warn, unit)
  local v = cfg[key]
  if type(v) ~= "number" or v <= (min_val - 1) then
    cfg[key] = default
    warn(key .. " fehlt/ungültig; default=" .. tostring(default) .. (unit or ""))
  elseif max_val and v > max_val then
    cfg[key] = max_val
    warn(key .. " zu hoch; clamp=" .. tostring(max_val) .. (unit or ""))
  end
end

local function require_bool(cfg, key, default, warn)
  if type(cfg[key]) ~= "boolean" then
    cfg[key] = default
    warn(key .. " fehlt/ungültig; default=" .. tostring(default))
  end
end

local function require_table(cfg, key, default_fn, warn)
  if type(cfg[key]) ~= "table" then
    cfg[key] = default_fn()
    warn(key .. " fehlt/ungültig; auf Default zurückgesetzt")
  end
end

local function optional_string(cfg, key, default, warn)
  if cfg[key] ~= nil and type(cfg[key]) ~= "string" then
    cfg[key] = default
    warn(key .. " ungültig; default=" .. tostring(default))
  end
end

function M.normalize(config_values, defaults, utils, add_warning)
  local function warn(msg)
    if add_warning then add_warning(msg) end
  end

  -- node_id
  local normalized = utils.normalize_node_id(config_values.node_id)
  if normalized == "UNKNOWN" then
    config_values.node_id = defaults.node_id
    warn("node_id fehlt/ungültig; default=" .. tostring(defaults.node_id))
  else
    config_values.node_id = normalized
  end

  -- Basis-Felder
  if type(config_values.role) ~= "string" then
    config_values.role = defaults.role
    warn("role fehlt/ungültig; default=" .. tostring(defaults.role))
  end
  require_bool(config_values, "debug_logging",      defaults.debug_logging,      warn)
  require_bool(config_values, "reset_log_on_start", defaults.reset_log_on_start, warn)

  -- Modem-Overrides (optional)
  optional_string(config_values, "wireless_modem", defaults.wireless_modem, warn)
  optional_string(config_values, "wired_modem",    defaults.wired_modem,    warn)
  optional_string(config_values, "matrix",         defaults.matrix,         warn)

  -- Matrix-Listen
  require_table(config_values, "matrix_names",   function() return utils.deep_copy(defaults.matrix_names)   end, warn)
  require_table(config_values, "matrix_aliases", function() return utils.deep_copy(defaults.matrix_aliases) end, warn)
  require_table(config_values, "cubes",          function() return utils.deep_copy(defaults.cubes)          end, warn)

  -- Discovery
  clamp_num(config_values, "scan_interval",                    0,   60,    defaults.scan_interval,                    warn, "s")
  clamp_num(config_values, "discovery_force_rescan_interval",  0,   3600,  defaults.discovery_force_rescan_interval,  warn, "s")

  -- Matrix-Metriken
  clamp_num(config_values, "matrix_metric_poll_interval",       0,  30,    defaults.matrix_metric_poll_interval,       warn, "s")
  clamp_num(config_values, "matrix_metric_call_budget",         0,  64,    defaults.matrix_metric_call_budget,         warn)
  clamp_num(config_values, "matrix_metric_time_budget_ms",    100,  10000, defaults.matrix_metric_time_budget_ms,      warn, "ms")
  clamp_num(config_values, "matrix_metric_slow_call_ms",       50,  5000,  defaults.matrix_metric_slow_call_ms,        warn, "ms")
  clamp_num(config_values, "matrix_metric_slow_poll_multiplier", 1, 30,    defaults.matrix_metric_slow_poll_multiplier, warn, "x")
  clamp_num(config_values, "matrix_metric_per_matrix_budget",   0,  4,     defaults.matrix_metric_per_matrix_budget,   warn)
  clamp_num(config_values, "matrix_sample_min_tick_spacing_ms", 100, 10000, defaults.matrix_sample_min_tick_spacing_ms, warn, "ms")

  -- Matrix-Komponenten
  clamp_num(config_values, "matrix_component_poll_interval",    0,  300,   defaults.matrix_component_poll_interval,    warn, "s")
  clamp_num(config_values, "matrix_component_call_budget",      0,  12,    defaults.matrix_component_call_budget,      warn)
  clamp_num(config_values, "matrix_component_time_budget_ms",  50,  5000,  defaults.matrix_component_time_budget_ms,   warn, "ms")

  -- UI
  clamp_num(config_values, "ui_refresh_interval", 0, nil, defaults.ui_refresh_interval, warn, "s")
  clamp_num(config_values, "ui_scale",            0, nil, defaults.ui_scale,            warn)

  -- Monitor
  require_table(config_values, "monitor", function() return utils.deep_copy(defaults.monitor) end, warn)
  optional_string(config_values.monitor, "preferred_name", defaults.monitor.preferred_name, warn)
  if type(config_values.monitor.strategy) ~= "string" then
    config_values.monitor.strategy = defaults.monitor.strategy
    warn("monitor.strategy ungültig; default=" .. tostring(defaults.monitor.strategy))
  end

  -- Storage-Filter
  require_table(config_values, "storage_filters", function() return utils.deep_copy(defaults.storage_filters) end, warn)
  if config_values.storage_filters.include_names ~= nil
      and type(config_values.storage_filters.include_names) ~= "table" then
    config_values.storage_filters.include_names = defaults.storage_filters.include_names
    warn("storage_filters.include_names ungültig; auf Default zurückgesetzt")
  end
  require_table(config_values.storage_filters, "exclude_names",
    function() return utils.deep_copy(defaults.storage_filters.exclude_names) end, warn)
  require_table(config_values.storage_filters, "prefer_names",
    function() return utils.deep_copy(defaults.storage_filters.prefer_names) end, warn)

  -- Timing
  clamp_num(config_values, "heartbeat_interval", 0, 60, defaults.heartbeat_interval, warn, "s")
  clamp_num(config_values, "status_interval",    0, 60, defaults.status_interval,    warn, "s")

  -- Kanäle
  require_table(config_values, "channels", function() return utils.deep_copy(defaults.channels) end, warn)
  if type(config_values.channels.control) ~= "number" then
    config_values.channels.control = defaults.channels.control
    warn("channels.control fehlt; default=" .. tostring(defaults.channels.control))
  end
  if type(config_values.channels.status) ~= "number" then
    config_values.channels.status = defaults.channels.status
    warn("channels.status fehlt; default=" .. tostring(defaults.channels.status))
  end

  -- Comms
  require_table(config_values, "comms", function() return utils.deep_copy(defaults.comms) end, warn)

  return config_values
end

return M
