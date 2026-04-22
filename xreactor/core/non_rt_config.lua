local M = {}

local function clamp_number(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

function M.apply_common(config_values, defaults, add_warning, utils)
  local normalized = utils.normalize_node_id(config_values.node_id)
  if normalized == "UNKNOWN" then
    config_values.node_id = defaults.node_id
    add_warning("node_id missing/invalid; defaulting to " .. tostring(defaults.node_id))
  else
    config_values.node_id = normalized
  end

  if type(config_values.role) ~= "string" then
    config_values.role = defaults.role
    add_warning("role missing/invalid; defaulting to " .. tostring(defaults.role))
  end
  if type(config_values.debug_logging) ~= "boolean" then
    config_values.debug_logging = defaults.debug_logging
    add_warning("debug_logging missing/invalid; defaulting to " .. tostring(defaults.debug_logging))
  end
  if type(config_values.reset_log_on_start) ~= "boolean" then
    config_values.reset_log_on_start = defaults.reset_log_on_start
    add_warning("reset_log_on_start missing/invalid; defaulting to " .. tostring(defaults.reset_log_on_start))
  end
  if config_values.wireless_modem ~= nil and type(config_values.wireless_modem) ~= "string" then
    config_values.wireless_modem = defaults.wireless_modem
    add_warning("wireless_modem invalid; defaulting to " .. tostring(defaults.wireless_modem))
  end
  if config_values.wired_modem ~= nil and type(config_values.wired_modem) ~= "string" then
    config_values.wired_modem = defaults.wired_modem
    add_warning("wired_modem invalid; defaulting to " .. tostring(defaults.wired_modem))
  end

  if type(config_values.heartbeat_interval) ~= "number" or config_values.heartbeat_interval <= 0 then
    config_values.heartbeat_interval = defaults.heartbeat_interval
    add_warning("heartbeat_interval missing/invalid; defaulting to " .. tostring(defaults.heartbeat_interval))
  else
    local clamped = clamp_number(config_values.heartbeat_interval, 1, 60)
    if clamped ~= config_values.heartbeat_interval then
      config_values.heartbeat_interval = clamped
      add_warning("heartbeat_interval too high; clamping to 60s")
    end
  end

  if type(config_values.status_interval) ~= "number" or config_values.status_interval <= 0 then
    config_values.status_interval = defaults.status_interval
    add_warning("status_interval missing/invalid; defaulting to " .. tostring(defaults.status_interval))
  else
    local clamped = clamp_number(config_values.status_interval, 1, 60)
    if clamped ~= config_values.status_interval then
      config_values.status_interval = clamped
      add_warning("status_interval too high; clamping to 60s")
    end
  end

  if type(config_values.discovery_interval) ~= "number" or config_values.discovery_interval <= 0 then
    config_values.discovery_interval = defaults.discovery_interval
    add_warning("discovery_interval missing/invalid; defaulting to " .. tostring(defaults.discovery_interval))
  else
    local clamped = clamp_number(config_values.discovery_interval, 1, 300)
    if clamped ~= config_values.discovery_interval then
      config_values.discovery_interval = clamped
      add_warning("discovery_interval too high; clamping to 300s")
    end
  end

  if type(config_values.channels) ~= "table" then
    config_values.channels = utils.deep_copy(defaults.channels)
    add_warning("channels missing/invalid; defaulting to control/status defaults")
  end
  if type(config_values.channels.control) ~= "number" then
    config_values.channels.control = defaults.channels.control
    add_warning("channels.control missing/invalid; defaulting to " .. tostring(defaults.channels.control))
  end
  if type(config_values.channels.status) ~= "number" then
    config_values.channels.status = defaults.channels.status
    add_warning("channels.status missing/invalid; defaulting to " .. tostring(defaults.channels.status))
  end

  if type(config_values.comms) ~= "table" then
    config_values.comms = utils.deep_copy(defaults.comms)
    add_warning("comms config missing/invalid; defaulting to comms defaults")
  end
end

return M
