local M = {}

function M.validate_config(config_values, defaults, add_warning, utils)
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
  if config_values.modem ~= nil and type(config_values.modem) ~= "string" then
    config_values.modem = defaults.modem
    add_warning("modem invalid; defaulting to " .. tostring(defaults.modem))
  end
  if type(config_values.reactors) ~= "table" then
    config_values.reactors = utils.deep_copy(defaults.reactors)
    add_warning("reactors missing/invalid; defaulting to configured list")
  end
  if type(config_values.turbines) ~= "table" then
    config_values.turbines = utils.deep_copy(defaults.turbines)
    add_warning("turbines missing/invalid; defaulting to configured list")
  end
  if type(config_values.heartbeat_interval) ~= "number" or config_values.heartbeat_interval <= 0 then
    config_values.heartbeat_interval = defaults.heartbeat_interval
    add_warning("heartbeat_interval missing/invalid; defaulting to " .. tostring(defaults.heartbeat_interval))
  elseif config_values.heartbeat_interval > 60 then
    config_values.heartbeat_interval = 60
    add_warning("heartbeat_interval too high; clamping to 60s")
  end
  if type(config_values.scan_interval) ~= "number" or config_values.scan_interval <= 0 then
    config_values.scan_interval = defaults.scan_interval
    add_warning("scan_interval missing/invalid; defaulting to " .. tostring(defaults.scan_interval))
  end
  if type(config_values.startup_watchdog_s) ~= "number" or config_values.startup_watchdog_s <= 0 then
    config_values.startup_watchdog_s = defaults.startup_watchdog_s
    add_warning("startup_watchdog_s missing/invalid; defaulting to " .. tostring(defaults.startup_watchdog_s))
  elseif config_values.startup_watchdog_s > 600 then
    config_values.startup_watchdog_s = 600
    add_warning("startup_watchdog_s too high; clamping to 600s")
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
  if type(config_values.safety) ~= "table" then
    config_values.safety = utils.deep_copy(defaults.safety)
    add_warning("safety missing/invalid; defaulting to safety defaults")
  end
  if type(config_values.safety.max_temperature) ~= "number" then
    config_values.safety.max_temperature = defaults.safety.max_temperature
    add_warning("safety.max_temperature missing/invalid; defaulting to " .. tostring(defaults.safety.max_temperature))
  end
  if type(config_values.safety.temperature_hysteresis) ~= "number" then
    config_values.safety.temperature_hysteresis = defaults.safety.temperature_hysteresis
    add_warning("safety.temperature_hysteresis missing/invalid; defaulting to " .. tostring(defaults.safety.temperature_hysteresis))
  end
  if type(config_values.safety.temperature_trip_samples) ~= "number" then
    config_values.safety.temperature_trip_samples = defaults.safety.temperature_trip_samples
    add_warning("safety.temperature_trip_samples missing/invalid; defaulting to " .. tostring(defaults.safety.temperature_trip_samples))
  end
  if type(config_values.safety.max_rpm) ~= "number" then
    config_values.safety.max_rpm = defaults.safety.max_rpm
    add_warning("safety.max_rpm missing/invalid; defaulting to " .. tostring(defaults.safety.max_rpm))
  end
  if type(config_values.safety.min_water) ~= "number" then
    config_values.safety.min_water = defaults.safety.min_water
    add_warning("safety.min_water missing/invalid; defaulting to " .. tostring(defaults.safety.min_water))
  end
  if type(config_values.autonom) ~= "table" then
    config_values.autonom = utils.deep_copy(defaults.autonom)
    add_warning("autonom missing/invalid; defaulting to autonom defaults")
  end
  if type(config_values.autonom.control_rod_level) ~= "number" then
    config_values.autonom.control_rod_level = defaults.autonom.control_rod_level
    add_warning("autonom.control_rod_level missing/invalid; defaulting to " .. tostring(defaults.autonom.control_rod_level))
  end
  if type(config_values.autonom.max_rpm) ~= "number" then
    config_values.autonom.max_rpm = defaults.autonom.max_rpm
    add_warning("autonom.max_rpm missing/invalid; defaulting to " .. tostring(defaults.autonom.max_rpm))
  end
  if type(config_values.autonom.min_flow) ~= "number" then
    config_values.autonom.min_flow = defaults.autonom.min_flow
    add_warning("autonom.min_flow missing/invalid; defaulting to " .. tostring(defaults.autonom.min_flow))
  end
  if type(config_values.autonom.max_flow) ~= "number" then
    config_values.autonom.max_flow = defaults.autonom.max_flow
    add_warning("autonom.max_flow missing/invalid; defaulting to " .. tostring(defaults.autonom.max_flow))
  end
  if type(config_values.autonom.flow_step) ~= "number" then
    config_values.autonom.flow_step = defaults.autonom.flow_step
    add_warning("autonom.flow_step missing/invalid; defaulting to " .. tostring(defaults.autonom.flow_step))
  end
  if type(config_values.autonom.ramp_step) ~= "number" then
    config_values.autonom.ramp_step = defaults.autonom.ramp_step
    add_warning("autonom.ramp_step missing/invalid; defaulting to " .. tostring(defaults.autonom.ramp_step))
  end
  if type(config_values.autonom.min_rods) ~= "number" then
    config_values.autonom.min_rods = defaults.autonom.min_rods
    add_warning("autonom.min_rods missing/invalid; defaulting to " .. tostring(defaults.autonom.min_rods))
  end
  if type(config_values.autonom.max_rods) ~= "number" then
    config_values.autonom.max_rods = defaults.autonom.max_rods
    add_warning("autonom.max_rods missing/invalid; defaulting to " .. tostring(defaults.autonom.max_rods))
  end
  if type(config_values.autonom.reactor_adjust_interval) ~= "number" then
    config_values.autonom.reactor_adjust_interval = defaults.autonom.reactor_adjust_interval
    add_warning("autonom.reactor_adjust_interval missing/invalid; defaulting to " .. tostring(defaults.autonom.reactor_adjust_interval))
  end
  if type(config_values.autonom.steam_reserve) ~= "number" then
    config_values.autonom.steam_reserve = defaults.autonom.steam_reserve
    add_warning("autonom.steam_reserve missing/invalid; defaulting to " .. tostring(defaults.autonom.steam_reserve))
  end
  if type(config_values.autonom.steam_deficit) ~= "number" then
    config_values.autonom.steam_deficit = defaults.autonom.steam_deficit
    add_warning("autonom.steam_deficit missing/invalid; defaulting to " .. tostring(defaults.autonom.steam_deficit))
  end
  if type(config_values.monitor_interval) ~= "number" or config_values.monitor_interval <= 0 then
    config_values.monitor_interval = defaults.monitor_interval
    add_warning("monitor_interval missing/invalid; defaulting to " .. tostring(defaults.monitor_interval))
  end
  if type(config_values.monitor_scale) ~= "number" or config_values.monitor_scale <= 0 then
    config_values.monitor_scale = defaults.monitor_scale
    add_warning("monitor_scale missing/invalid; defaulting to " .. tostring(defaults.monitor_scale))
  end
  if type(config_values.status_interval) ~= "number" or config_values.status_interval <= 0 then
    config_values.status_interval = defaults.status_interval
    add_warning("status_interval missing/invalid; defaulting to " .. tostring(defaults.status_interval))
  elseif config_values.status_interval > 60 then
    config_values.status_interval = 60
    add_warning("status_interval too high; clamping to 60s")
  end
  if type(config_values.comms) ~= "table" then
    config_values.comms = utils.deep_copy(defaults.comms)
    add_warning("comms config missing/invalid; defaulting to comms defaults")
  end
  if config_values.status_log ~= nil and type(config_values.status_log) ~= "boolean" then
    config_values.status_log = defaults.status_log
    add_warning("status_log invalid; defaulting to " .. tostring(defaults.status_log))
  end
end

local function clamp_nonneg(value, fallback)
  if type(value) ~= "number" or value < 0 then
    return fallback
  end
  return value
end

function M.normalize_rails(config, defaults, utils, safety, min_flow, max_flow)
  local function normalize_rail(section, section_defaults)
    local data = config.rails[section] or {}
    data.deadband_up = clamp_nonneg(data.deadband_up, section_defaults.deadband_up)
    data.deadband_down = clamp_nonneg(data.deadband_down, section_defaults.deadband_down)
    data.hysteresis_up = clamp_nonneg(data.hysteresis_up, section_defaults.hysteresis_up)
    data.hysteresis_down = clamp_nonneg(data.hysteresis_down, section_defaults.hysteresis_down)
    data.max_step_up = clamp_nonneg(data.max_step_up, section_defaults.max_step_up)
    data.max_step_down = clamp_nonneg(data.max_step_down, section_defaults.max_step_down)
    data.cooldown_s = clamp_nonneg(data.cooldown_s, section_defaults.cooldown_s)
    data.min = type(data.min) == "number" and data.min or section_defaults.min
    data.max = type(data.max) == "number" and data.max or section_defaults.max
    if section == "turbine_flow" then
      data.min = safety.clamp(data.min, min_flow, max_flow)
      data.max = safety.clamp(data.max, min_flow, max_flow)
      if data.min > data.max then
        data.min, data.max = min_flow, max_flow
      end
      data.max_step_up = math.max(data.max_step_up, section_defaults.max_step_up)
      data.max_step_down = math.max(data.max_step_down, section_defaults.max_step_down)
      data.min_step_up = clamp_nonneg(data.min_step_up, section_defaults.min_step_up)
      data.min_step_down = clamp_nonneg(data.min_step_down, section_defaults.min_step_down)
      data.step_per_rpm_up = clamp_nonneg(data.step_per_rpm_up, section_defaults.step_per_rpm_up)
      data.step_per_rpm_down = clamp_nonneg(data.step_per_rpm_down, section_defaults.step_per_rpm_down)
      data.adaptive_step = data.adaptive_step ~= false
      data.settle_timeout_s = clamp_nonneg(data.settle_timeout_s, section_defaults.settle_timeout_s)
      data.confirm_tolerance = clamp_nonneg(data.confirm_tolerance, section_defaults.confirm_tolerance)
      data.effective_min_samples = math.max(1, math.floor(tonumber(data.effective_min_samples) or section_defaults.effective_min_samples))
    end
    if type(data.ema_alpha) ~= "number" or data.ema_alpha <= 0 or data.ema_alpha >= 1 then
      data.ema_alpha = section_defaults.ema_alpha
    end
    config.rails[section] = data
  end

  normalize_rail("turbine_flow", defaults.rails.turbine_flow)
  local rod_defaults = utils.deep_copy(defaults.rails.reactor_rods)
  rod_defaults.deadband_up = config.autonom.steam_reserve
  rod_defaults.deadband_down = config.autonom.steam_deficit
  normalize_rail("reactor_rods", rod_defaults)

  local coil = config.rails.coil or {}
  coil.engage_rpm = clamp_nonneg(coil.engage_rpm, defaults.rails.coil.engage_rpm)
  coil.disengage_rpm = clamp_nonneg(coil.disengage_rpm, defaults.rails.coil.disengage_rpm)
  coil.cooldown_s = clamp_nonneg(coil.cooldown_s, defaults.rails.coil.cooldown_s)
  if type(coil.ema_alpha) ~= "number" or coil.ema_alpha <= 0 or coil.ema_alpha >= 1 then
    coil.ema_alpha = defaults.rails.coil.ema_alpha
  end
  if coil.disengage_rpm > coil.engage_rpm then
    coil.disengage_rpm = coil.engage_rpm
  end
  config.rails.coil = coil
end

return M
