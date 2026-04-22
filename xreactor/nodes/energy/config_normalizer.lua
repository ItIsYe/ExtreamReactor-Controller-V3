local M = {}

function M.normalize(config_values, defaults, utils, add_warning)
  local function warn(msg)
    if add_warning then add_warning(msg) end
  end
  local normalized = utils.normalize_node_id(config_values.node_id)
  if normalized == "UNKNOWN" then
    config_values.node_id = defaults.node_id
    warn("node_id missing/invalid; defaulting to " .. tostring(defaults.node_id))
  else
    config_values.node_id = normalized
  end
  if type(config_values.role) ~= "string" then config_values.role = defaults.role; warn("role missing/invalid; defaulting to " .. tostring(defaults.role)) end
  if type(config_values.debug_logging) ~= "boolean" then config_values.debug_logging = defaults.debug_logging; warn("debug_logging missing/invalid; defaulting to " .. tostring(defaults.debug_logging)) end
  if type(config_values.reset_log_on_start) ~= "boolean" then config_values.reset_log_on_start = defaults.reset_log_on_start; warn("reset_log_on_start missing/invalid; defaulting to " .. tostring(defaults.reset_log_on_start)) end
  if config_values.wireless_modem ~= nil and type(config_values.wireless_modem) ~= "string" then config_values.wireless_modem = defaults.wireless_modem; warn("wireless_modem invalid; defaulting to " .. tostring(defaults.wireless_modem)) end
  if config_values.wired_modem ~= nil and type(config_values.wired_modem) ~= "string" then config_values.wired_modem = defaults.wired_modem; warn("wired_modem invalid; defaulting to " .. tostring(defaults.wired_modem)) end
  if config_values.matrix ~= nil and type(config_values.matrix) ~= "string" then config_values.matrix = defaults.matrix; warn("matrix invalid; defaulting to " .. tostring(defaults.matrix)) end
  if type(config_values.matrix_names) ~= "table" then config_values.matrix_names = utils.deep_copy(defaults.matrix_names); warn("matrix_names missing/invalid; defaulting to configured list") end
  if type(config_values.matrix_aliases) ~= "table" then config_values.matrix_aliases = utils.deep_copy(defaults.matrix_aliases); warn("matrix_aliases missing/invalid; defaulting to configured mapping") end
  if type(config_values.cubes) ~= "table" then config_values.cubes = utils.deep_copy(defaults.cubes); warn("cubes missing/invalid; defaulting to configured list") end
  if type(config_values.scan_interval) ~= "number" or config_values.scan_interval <= 0 then config_values.scan_interval = defaults.scan_interval; warn("scan_interval missing/invalid; defaulting to " .. tostring(defaults.scan_interval)) elseif config_values.scan_interval > 60 then config_values.scan_interval = 60; warn("scan_interval too high; clamping to 60s") end
  if type(config_values.discovery_force_rescan_interval) ~= "number" or config_values.discovery_force_rescan_interval <= 0 then config_values.discovery_force_rescan_interval = defaults.discovery_force_rescan_interval; warn("discovery_force_rescan_interval missing/invalid; defaulting to " .. tostring(defaults.discovery_force_rescan_interval)) elseif config_values.discovery_force_rescan_interval > 3600 then config_values.discovery_force_rescan_interval = 3600; warn("discovery_force_rescan_interval too high; clamping to 3600s") end
  if type(config_values.matrix_metric_poll_interval) ~= "number" or config_values.matrix_metric_poll_interval <= 0 then config_values.matrix_metric_poll_interval = defaults.matrix_metric_poll_interval; warn("matrix_metric_poll_interval missing/invalid; defaulting to " .. tostring(defaults.matrix_metric_poll_interval)) elseif config_values.matrix_metric_poll_interval > 30 then config_values.matrix_metric_poll_interval = 30; warn("matrix_metric_poll_interval too high; clamping to 30s") end
  if type(config_values.matrix_metric_call_budget) ~= "number" or config_values.matrix_metric_call_budget <= 0 then config_values.matrix_metric_call_budget = defaults.matrix_metric_call_budget; warn("matrix_metric_call_budget missing/invalid; defaulting to " .. tostring(defaults.matrix_metric_call_budget)) elseif config_values.matrix_metric_call_budget > 64 then config_values.matrix_metric_call_budget = 64; warn("matrix_metric_call_budget too high; clamping to 64") end
  if type(config_values.matrix_metric_time_budget_ms) ~= "number" or config_values.matrix_metric_time_budget_ms < 100 then config_values.matrix_metric_time_budget_ms = defaults.matrix_metric_time_budget_ms; warn("matrix_metric_time_budget_ms missing/invalid; defaulting to " .. tostring(defaults.matrix_metric_time_budget_ms)) elseif config_values.matrix_metric_time_budget_ms > 10000 then config_values.matrix_metric_time_budget_ms = 10000; warn("matrix_metric_time_budget_ms too high; clamping to 10000ms") end
  if type(config_values.matrix_metric_slow_call_ms) ~= "number" or config_values.matrix_metric_slow_call_ms < 50 then config_values.matrix_metric_slow_call_ms = defaults.matrix_metric_slow_call_ms; warn("matrix_metric_slow_call_ms missing/invalid; defaulting to " .. tostring(defaults.matrix_metric_slow_call_ms)) elseif config_values.matrix_metric_slow_call_ms > 5000 then config_values.matrix_metric_slow_call_ms = 5000; warn("matrix_metric_slow_call_ms too high; clamping to 5000ms") end
  if type(config_values.matrix_metric_slow_poll_multiplier) ~= "number" or config_values.matrix_metric_slow_poll_multiplier < 1 then config_values.matrix_metric_slow_poll_multiplier = defaults.matrix_metric_slow_poll_multiplier; warn("matrix_metric_slow_poll_multiplier missing/invalid; defaulting to " .. tostring(defaults.matrix_metric_slow_poll_multiplier)) elseif config_values.matrix_metric_slow_poll_multiplier > 30 then config_values.matrix_metric_slow_poll_multiplier = 30; warn("matrix_metric_slow_poll_multiplier too high; clamping to 30x") end
  if type(config_values.matrix_metric_per_matrix_budget) ~= "number" or config_values.matrix_metric_per_matrix_budget <= 0 then config_values.matrix_metric_per_matrix_budget = defaults.matrix_metric_per_matrix_budget; warn("matrix_metric_per_matrix_budget missing/invalid; defaulting to " .. tostring(defaults.matrix_metric_per_matrix_budget)) elseif config_values.matrix_metric_per_matrix_budget > 4 then config_values.matrix_metric_per_matrix_budget = 4; warn("matrix_metric_per_matrix_budget too high; clamping to 4") end
  if type(config_values.matrix_component_poll_interval) ~= "number" or config_values.matrix_component_poll_interval <= 0 then config_values.matrix_component_poll_interval = defaults.matrix_component_poll_interval; warn("matrix_component_poll_interval missing/invalid; defaulting to " .. tostring(defaults.matrix_component_poll_interval)) elseif config_values.matrix_component_poll_interval > 300 then config_values.matrix_component_poll_interval = 300; warn("matrix_component_poll_interval too high; clamping to 300s") end
  if type(config_values.matrix_component_call_budget) ~= "number" or config_values.matrix_component_call_budget <= 0 then config_values.matrix_component_call_budget = defaults.matrix_component_call_budget; warn("matrix_component_call_budget missing/invalid; defaulting to " .. tostring(defaults.matrix_component_call_budget)) elseif config_values.matrix_component_call_budget > 12 then config_values.matrix_component_call_budget = 12; warn("matrix_component_call_budget too high; clamping to 12") end
  if type(config_values.matrix_component_time_budget_ms) ~= "number" or config_values.matrix_component_time_budget_ms < 50 then config_values.matrix_component_time_budget_ms = defaults.matrix_component_time_budget_ms; warn("matrix_component_time_budget_ms missing/invalid; defaulting to " .. tostring(defaults.matrix_component_time_budget_ms)) elseif config_values.matrix_component_time_budget_ms > 5000 then config_values.matrix_component_time_budget_ms = 5000; warn("matrix_component_time_budget_ms too high; clamping to 5000ms") end
  if type(config_values.ui_refresh_interval) ~= "number" or config_values.ui_refresh_interval <= 0 then config_values.ui_refresh_interval = defaults.ui_refresh_interval; warn("ui_refresh_interval missing/invalid; defaulting to " .. tostring(defaults.ui_refresh_interval)) end
  if type(config_values.ui_scale) ~= "number" or config_values.ui_scale <= 0 then config_values.ui_scale = defaults.ui_scale; warn("ui_scale missing/invalid; defaulting to " .. tostring(defaults.ui_scale)) end
  if type(config_values.monitor) ~= "table" then config_values.monitor = utils.deep_copy(defaults.monitor); warn("monitor config missing/invalid; defaulting to configured monitor options") end
  if config_values.monitor.preferred_name ~= nil and type(config_values.monitor.preferred_name) ~= "string" then config_values.monitor.preferred_name = defaults.monitor.preferred_name; warn("monitor.preferred_name invalid; defaulting to configured value") end
  if type(config_values.monitor.strategy) ~= "string" then config_values.monitor.strategy = defaults.monitor.strategy; warn("monitor.strategy invalid; defaulting to " .. tostring(defaults.monitor.strategy)) end
  if type(config_values.storage_filters) ~= "table" then config_values.storage_filters = utils.deep_copy(defaults.storage_filters); warn("storage_filters missing/invalid; defaulting to configured filters") end
  if config_values.storage_filters.include_names ~= nil and type(config_values.storage_filters.include_names) ~= "table" then config_values.storage_filters.include_names = defaults.storage_filters.include_names; warn("storage_filters.include_names invalid; defaulting to configured value") end
  if type(config_values.storage_filters.exclude_names) ~= "table" then config_values.storage_filters.exclude_names = utils.deep_copy(defaults.storage_filters.exclude_names); warn("storage_filters.exclude_names missing/invalid; defaulting to configured list") end
  if type(config_values.storage_filters.prefer_names) ~= "table" then config_values.storage_filters.prefer_names = utils.deep_copy(defaults.storage_filters.prefer_names); warn("storage_filters.prefer_names missing/invalid; defaulting to configured list") end
  if type(config_values.heartbeat_interval) ~= "number" or config_values.heartbeat_interval <= 0 then
    config_values.heartbeat_interval = defaults.heartbeat_interval
    warn("heartbeat_interval missing/invalid; defaulting to " .. tostring(defaults.heartbeat_interval))
  elseif config_values.heartbeat_interval > 60 then
    config_values.heartbeat_interval = 60
    warn("heartbeat_interval too high; clamping to 60s")
  end
  if type(config_values.status_interval) ~= "number" or config_values.status_interval <= 0 then
    config_values.status_interval = defaults.status_interval
    warn("status_interval missing/invalid; defaulting to " .. tostring(defaults.status_interval))
  elseif config_values.status_interval > 60 then
    config_values.status_interval = 60
    warn("status_interval too high; clamping to 60s")
  end
  if type(config_values.channels) ~= "table" then
    config_values.channels = utils.deep_copy(defaults.channels)
    warn("channels missing/invalid; defaulting to control/status defaults")
  end
  if type(config_values.channels.control) ~= "number" then
    config_values.channels.control = defaults.channels.control
    warn("channels.control missing/invalid; defaulting to " .. tostring(defaults.channels.control))
  end
  if type(config_values.channels.status) ~= "number" then
    config_values.channels.status = defaults.channels.status
    warn("channels.status missing/invalid; defaulting to " .. tostring(defaults.channels.status))
  end
  if type(config_values.comms) ~= "table" then
    config_values.comms = utils.deep_copy(defaults.comms)
    warn("comms config missing/invalid; defaulting to comms defaults")
  end
  return config_values
end

return M
