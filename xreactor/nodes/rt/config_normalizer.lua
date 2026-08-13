local M = {}

local function clamp_range(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

function M.migrate_legacy_paths(config_values, add_warning)
  if type(config_values) ~= "table" then
    return
  end
  local runtime_ctx = type(config_values.runtime_ctx) == "table" and config_values.runtime_ctx or nil
  if runtime_ctx and config_values.monitor == nil then
    if type(runtime_ctx.monitor) == "string" then
      config_values.monitor = runtime_ctx.monitor
      add_warning("legacy runtime_ctx.monitor detected; mapped runtime_ctx.monitor -> monitor")
    elseif type(runtime_ctx.mon) == "string" then
      config_values.monitor = runtime_ctx.mon
      add_warning("legacy runtime_ctx.mon detected; mapped runtime_ctx.mon -> monitor")
    end
  elseif runtime_ctx then
    if type(runtime_ctx.monitor) == "string" and config_values.monitor ~= runtime_ctx.monitor then
      add_warning("legacy runtime_ctx.monitor ignored because monitor override is set")
    end
    if type(runtime_ctx.mon) == "string" and config_values.monitor ~= runtime_ctx.mon then
      add_warning("legacy runtime_ctx.mon ignored because monitor override is set")
    end
  end
end

-- Migriert gezielt nur die historischen Default-WERTE (autonom.
-- reactor_adjust_interval=5.0 / _individual=1.0, aus der Zeit vor der
-- 10-Hz-Cadence) -- ein bewusst vom Nutzer gesetzter anderer Wert bleibt
-- unangetastet. Die generische type-Normalisierung in validate_config()
-- fasst valide-aber-veraltete Zahlen sonst nicht an, eine bereits
-- installierte Config behielte dadurch dauerhaft die alte, zu langsame
-- Regelkadenz. Gesteuert ueber config.version, laeuft garantiert nur
-- einmal pro Installation (main.lua persistiert das Ergebnis sofort danach).
local RT_CONFIG_VERSION_INTERVAL_MIGRATION = 5
local LEGACY_REACTOR_ADJUST_INTERVAL = 5.0
local LEGACY_REACTOR_ADJUST_INTERVAL_INDIVIDUAL = 1.0

function M.migrate_schema_version(config_values, defaults, add_warning)
  if type(config_values) ~= "table" then
    return false
  end
  local from_version = tonumber(config_values.version) or 1
  local changed = false
  if from_version < RT_CONFIG_VERSION_INTERVAL_MIGRATION then
    local autonom = type(config_values.autonom) == "table" and config_values.autonom or nil
    if autonom then
      if autonom.reactor_adjust_interval == LEGACY_REACTOR_ADJUST_INTERVAL then
        autonom.reactor_adjust_interval = defaults.autonom.reactor_adjust_interval
        add_warning(string.format(
          "autonom.reactor_adjust_interval migrated from historical default %s -> %s (config schema v%d)",
          tostring(LEGACY_REACTOR_ADJUST_INTERVAL), tostring(defaults.autonom.reactor_adjust_interval), RT_CONFIG_VERSION_INTERVAL_MIGRATION))
        changed = true
      end
      if autonom.reactor_adjust_interval_individual == LEGACY_REACTOR_ADJUST_INTERVAL_INDIVIDUAL then
        autonom.reactor_adjust_interval_individual = defaults.autonom.reactor_adjust_interval_individual
        add_warning(string.format(
          "autonom.reactor_adjust_interval_individual migrated from historical default %s -> %s (config schema v%d)",
          tostring(LEGACY_REACTOR_ADJUST_INTERVAL_INDIVIDUAL), tostring(defaults.autonom.reactor_adjust_interval_individual), RT_CONFIG_VERSION_INTERVAL_MIGRATION))
        changed = true
      end
    end
  end
  if config_values.version ~= defaults.version then
    config_values.version = defaults.version
    changed = true
  end
  return changed
end

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
  if type(config_values.safety.coolant_hysteresis) ~= "number" then
    config_values.safety.coolant_hysteresis = defaults.safety.coolant_hysteresis
    add_warning("safety.coolant_hysteresis missing/invalid; defaulting to " .. tostring(defaults.safety.coolant_hysteresis))
  end
  if type(config_values.safety.coolant_trip_samples) ~= "number" then
    config_values.safety.coolant_trip_samples = defaults.safety.coolant_trip_samples
    add_warning("safety.coolant_trip_samples missing/invalid; defaulting to " .. tostring(defaults.safety.coolant_trip_samples))
  end
  if type(config_values.safety.coolant_invalid_grace_samples) ~= "number" then
    config_values.safety.coolant_invalid_grace_samples = defaults.safety.coolant_invalid_grace_samples
    add_warning("safety.coolant_invalid_grace_samples missing/invalid; defaulting to " .. tostring(defaults.safety.coolant_invalid_grace_samples))
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
  if type(config_values.autonom.reactor_adjust_interval) ~= "number" then
    config_values.autonom.reactor_adjust_interval = defaults.autonom.reactor_adjust_interval
    add_warning("autonom.reactor_adjust_interval missing/invalid; defaulting to " .. tostring(defaults.autonom.reactor_adjust_interval))
  end
  -- Normalisiert wie reactor_adjust_interval direkt darueber, statt nur
  -- ueber einen "or 0.10"-Fallback an der Verwendungsstelle in
  -- reactor_control.lua abgefangen zu werden.
  if type(config_values.autonom.reactor_adjust_interval_individual) ~= "number" then
    config_values.autonom.reactor_adjust_interval_individual = defaults.autonom.reactor_adjust_interval_individual
    add_warning("autonom.reactor_adjust_interval_individual missing/invalid; defaulting to " .. tostring(defaults.autonom.reactor_adjust_interval_individual))
  end
  if type(config_values.autonom.steam_reserve) ~= "number" then
    config_values.autonom.steam_reserve = defaults.autonom.steam_reserve
    add_warning("autonom.steam_reserve missing/invalid; defaulting to " .. tostring(defaults.autonom.steam_reserve))
  end
  if type(config_values.autonom.steam_deficit) ~= "number" then
    config_values.autonom.steam_deficit = defaults.autonom.steam_deficit
    add_warning("autonom.steam_deficit missing/invalid; defaulting to " .. tostring(defaults.autonom.steam_deficit))
  end
  -- Rod-Cap Migration: kanonischer Pfad ist rails.reactor_rods.min/.max.
  -- Ältere Pfade (autonom.regulator_min/max_rods, autonom.min/max_rods) werden
  -- auf rails.reactor_rods.min/.max migriert und dann verworfen.
  local autonom = config_values.autonom
  config_values.rails = config_values.rails or {}
  config_values.rails.reactor_rods = config_values.rails.reactor_rods or {}
  local rail_rods = config_values.rails.reactor_rods
  local defaults_rods = defaults.rails and defaults.rails.reactor_rods or {}

  -- Schritt 1: deprecated autonom.min_rods / max_rods -> autonom.regulator_min/max_rods
  if type(autonom.min_rods) == "number" and type(autonom.regulator_min_rods) ~= "number" then
    autonom.regulator_min_rods = autonom.min_rods
    add_warning("autonom.min_rods ist veraltet; bitte auf rails.reactor_rods.min umstellen")
  end
  if type(autonom.max_rods) == "number" and type(autonom.regulator_max_rods) ~= "number" then
    autonom.regulator_max_rods = autonom.max_rods
    add_warning("autonom.max_rods ist veraltet; bitte auf rails.reactor_rods.max umstellen")
  end

  -- Schritt 2: autonom.regulator_min/max_rods -> rails.reactor_rods.min/.max (falls noch nicht gesetzt)
  if type(autonom.regulator_min_rods) == "number" and type(rail_rods.min) ~= "number" then
    rail_rods.min = autonom.regulator_min_rods
    add_warning("autonom.regulator_min_rods ist veraltet; bitte auf rails.reactor_rods.min umstellen")
  end
  if type(autonom.regulator_max_rods) == "number" and type(rail_rods.max) ~= "number" then
    rail_rods.max = autonom.regulator_max_rods
    add_warning("autonom.regulator_max_rods ist veraltet; bitte auf rails.reactor_rods.max umstellen")
  end

  -- Schritt 3: Defaults setzen falls nichts konfiguriert
  if type(rail_rods.min) ~= "number" then
    rail_rods.min = type(defaults_rods.min) == "number" and defaults_rods.min or 0
    add_warning("rails.reactor_rods.min nicht gesetzt; default=" .. tostring(rail_rods.min))
  end
  if type(rail_rods.max) ~= "number" then
    rail_rods.max = type(defaults_rods.max) == "number" and defaults_rods.max or 100
    add_warning("rails.reactor_rods.max nicht gesetzt; default=" .. tostring(rail_rods.max))
  end

  -- Schritt 4: Clamp und Sanity-Check
  rail_rods.min = clamp_range(rail_rods.min, 0, 100)
  rail_rods.max = clamp_range(rail_rods.max, 0, 100)
  if rail_rods.min > rail_rods.max then
    rail_rods.min, rail_rods.max = rail_rods.max, rail_rods.min
    add_warning("rails.reactor_rods.min > .max; Werte getauscht")
  end

  -- Schritt 5: autonom.regulator_* auf kanonische Werte synchronisieren (Abwärtskompatibilität)
  autonom.regulator_min_rods = rail_rods.min
  autonom.regulator_max_rods = rail_rods.max
  -- Veraltete Felder bereinigen
  autonom.min_rods = nil
  autonom.max_rods = nil
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
  if type(value) ~= "number" then return fallback end
  return math.max(0, value)
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
  local steam_guard = config.rails.reactor_steam_guard or {}
  local steam_guard_defaults = defaults.rails.reactor_steam_guard or {}
  local default_high_ratio = tonumber(steam_guard_defaults.high_ratio) or 0.82
  local default_high_release_ratio = tonumber(steam_guard_defaults.high_release_ratio) or 0.74
  local default_critical_ratio = tonumber(steam_guard_defaults.critical_ratio) or 0.92
  local default_critical_release_ratio = tonumber(steam_guard_defaults.critical_release_ratio) or 0.86
  local default_force_close_step = tonumber(steam_guard_defaults.force_close_step) or 2
  local default_ema_alpha = tonumber(steam_guard_defaults.ema_alpha) or 0.2
  steam_guard.enabled = steam_guard.enabled ~= false
  steam_guard.high_ratio = type(steam_guard.high_ratio) == "number" and steam_guard.high_ratio or default_high_ratio
  steam_guard.high_release_ratio = type(steam_guard.high_release_ratio) == "number" and steam_guard.high_release_ratio or default_high_release_ratio
  steam_guard.critical_ratio = type(steam_guard.critical_ratio) == "number" and steam_guard.critical_ratio or default_critical_ratio
  steam_guard.critical_release_ratio = type(steam_guard.critical_release_ratio) == "number" and steam_guard.critical_release_ratio or default_critical_release_ratio
  steam_guard.force_close_step = clamp_nonneg(steam_guard.force_close_step, default_force_close_step)
  if type(steam_guard.ema_alpha) ~= "number" or steam_guard.ema_alpha <= 0 or steam_guard.ema_alpha >= 1 then
    steam_guard.ema_alpha = default_ema_alpha
  end
  steam_guard.high_ratio = clamp_range(steam_guard.high_ratio, 0, 1)
  steam_guard.high_release_ratio = clamp_range(steam_guard.high_release_ratio, 0, 1)
  steam_guard.critical_ratio = clamp_range(steam_guard.critical_ratio, 0, 1)
  steam_guard.critical_release_ratio = clamp_range(steam_guard.critical_release_ratio, 0, 1)
  if steam_guard.high_release_ratio > steam_guard.high_ratio then
    steam_guard.high_release_ratio = steam_guard.high_ratio
  end
  if steam_guard.critical_release_ratio > steam_guard.critical_ratio then
    steam_guard.critical_release_ratio = steam_guard.critical_ratio
  end
  if steam_guard.high_ratio > steam_guard.critical_ratio then
    steam_guard.high_ratio = steam_guard.critical_ratio
    if steam_guard.high_release_ratio > steam_guard.high_ratio then
      steam_guard.high_release_ratio = steam_guard.high_ratio
    end
  end
  config.rails.reactor_steam_guard = steam_guard

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

function M.apply_runtime_defaults(config, defaults, runtime)
  runtime = runtime or {}
  local deep_copy = runtime.deep_copy
  if type(deep_copy) ~= "function" then
    deep_copy = function(value)
      return value
    end
  end
  config.safety = config.safety or {}
  config.safety.max_temperature = config.safety.max_temperature or defaults.safety.max_temperature
  config.safety.temperature_hysteresis = config.safety.temperature_hysteresis or defaults.safety.temperature_hysteresis
  config.safety.temperature_trip_samples = config.safety.temperature_trip_samples or defaults.safety.temperature_trip_samples
  config.safety.max_rpm = config.safety.max_rpm or defaults.safety.max_rpm
  config.safety.min_water = config.safety.min_water or defaults.safety.min_water
  config.safety.coolant_hysteresis = config.safety.coolant_hysteresis or defaults.safety.coolant_hysteresis
  config.safety.coolant_trip_samples = config.safety.coolant_trip_samples or defaults.safety.coolant_trip_samples
  config.safety.coolant_invalid_grace_samples = config.safety.coolant_invalid_grace_samples or defaults.safety.coolant_invalid_grace_samples
  config.heartbeat_interval = config.heartbeat_interval or defaults.heartbeat_interval
  config.autonom = config.autonom or {}

  local target_rpm = runtime.target_rpm or defaults.autonom.max_rpm
  local min_flow = runtime.min_flow
  if type(min_flow) ~= "number" then
    min_flow = defaults.autonom.min_flow
  end
  local max_flow = runtime.max_flow
  if type(max_flow) ~= "number" then
    max_flow = defaults.autonom.max_flow
  end
  local flow_step = runtime.flow_step or defaults.autonom.flow_step
  local rod_tick = runtime.rod_tick or defaults.autonom.reactor_adjust_interval

  config.autonom.control_rod_level = config.autonom.control_rod_level or defaults.autonom.control_rod_level
  config.autonom.target_rpm = target_rpm
  config.autonom.max_rpm = math.max(config.autonom.max_rpm or target_rpm, target_rpm)
  config.autonom.min_flow = math.max(config.autonom.min_flow or min_flow, min_flow)
  config.autonom.max_flow = math.min(config.autonom.max_flow or max_flow, max_flow)
  config.autonom.flow_step = config.autonom.flow_step or flow_step
  config.autonom.ramp_step = config.autonom.ramp_step or config.autonom.flow_step
  -- regulator_min/max_rods werden in validate_config auf rails.reactor_rods.min/.max gesetzt
  -- und von dort synchronisiert. Kein separater Default hier nötig.
  config.autonom.reactor_adjust_interval = config.autonom.reactor_adjust_interval or rod_tick
  config.autonom.steam_reserve = config.autonom.steam_reserve or defaults.autonom.steam_reserve
  config.autonom.steam_deficit = config.autonom.steam_deficit or defaults.autonom.steam_deficit
  config.rails = config.rails or deep_copy(defaults.rails)
  config.rails.ramp_profiles = config.rails.ramp_profiles or deep_copy(defaults.rails.ramp_profiles)
  if type(runtime.normalize_rails) == "function" then
    runtime.normalize_rails(config, defaults)
  end
  config.monitor_interval = config.monitor_interval or defaults.monitor_interval
  config.monitor_scale = config.monitor_scale or defaults.monitor_scale
  config.scan_interval = config.scan_interval or defaults.scan_interval
  config.startup_watchdog_s = config.startup_watchdog_s or defaults.startup_watchdog_s
end

return M
