-- CONFIG
local CONFIG = {
  LOG_NAME = "rt", -- Log file name for this node.
  LOG_PREFIX = "RT", -- Default log prefix for RT events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_rt.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = "/xreactor/nodes/rt/config.lua", -- Config file path.
  TARGET_RPM = 900, -- Default turbine RPM target.
  RPM_TOLERANCE = 20, -- RPM tolerance for control loops.
  MIN_FLOW = 0, -- Minimum turbine flow.
  MAX_FLOW = 2000, -- Maximum turbine flow.
  FLOW_STEP = 50, -- Flow adjustment step size.
  COIL_ENGAGE_RPM = 850, -- RPM at which coils engage.
  COIL_DISENGAGE_RPM = 750, -- RPM at which coils disengage.
  START_FLOW = 0, -- Starting flow value when enabling turbines.
  ROD_TICK = 5.0, -- Control rod adjustment interval (seconds).
  ROD_MIN = 0, -- Minimum control rod insertion.
  ROD_MAX = 98, -- Maximum control rod insertion.
  INITIAL_ROD_LEVEL = 98, -- Initial rod level on startup.
  MIN_APPLY_INTERVAL = 1.5, -- Minimum interval between rod applications.
  REACTOR_STEP = 5, -- Reactor rod step adjustment.
  MIN_ACTIVE_RPM = 100, -- Minimum RPM to consider turbine active.
  RECEIVE_TIMEOUT = 0.2 -- Network receive timeout (seconds).
}
local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "rt",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
local require = bootstrap.require
local binding = require("nodes.rt.binding")
local discovery_log = require("nodes.rt.discovery_log")
local rails = require("core.control_rails")
local ensure_turbine_ctrl = require("core.turbine_ctrl")
local function get_turbine_ctrl(name)
  local ctrl = ensure_turbine_ctrl(name)
  if type(ctrl.rails) ~= "table" then
    ctrl.rails = {
      flow = rails.new_state(),
      coil = rails.new_state()
    }
  end
  return ctrl
end
local constants = require("shared.constants")
local colors = require("shared.colors")
local ui = require("core.ui")
local ui_router = require("core.ui_router")
local protocol = require("core.protocol")
local utils = require("core.utils")
local safety = require("core.safety")
local health = require("core.health")
local machine = require("core.state_machine")
local registry_lib = require("core.registry")
local fluid = require("core.fluid")
local reactor_adapter = require("adapters.reactor")
local turbine_adapter = require("adapters.turbine")
local monitor_adapter = require("adapters.monitor")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local discovery_service = require("services.discovery_service")
local telemetry_service = require("services.telemetry_service")
local control_service = require("services.control_service")
local turbine_regulator = require("core.turbine_regulator")
local monitor_ui = require("nodes.rt.monitor_ui")
local state_handlers = require("nodes.rt.state_handlers")
local status_snapshot_lib = require("nodes.rt.status_snapshot")
local startup_diagnostics = require("nodes.rt.startup_diagnostics")
local module_lifecycle = require("nodes.rt.module_lifecycle")
local command_handler = require("nodes.rt.command_handler")
local config_normalizer = require("nodes.rt.config_normalizer")
local flow_apply_helpers = require("nodes.rt.flow_apply_helpers")
local INFO = "INFO"
local DEBUG = "DEBUG"
local WARN = "WARN"
local function log(level, message)
  utils.log(CONFIG.LOG_PREFIX, message, level)
end
local DEFAULT_CONFIG = {
  role = constants.roles.RT_NODE, -- Node role identifier.
  node_id = "RT-1", -- Default node_id used if none is set.
  debug_logging = true, -- Keep enabled by default for RT stabilization diagnostics.
  reset_log_on_start = true, -- Truncate runtime log at startup to keep disk usage bounded.
  wireless_modem = nil, -- Autodetect wireless modem unless explicitly configured.
  wired_modem = nil, -- Optional wired modem side.
  modem = nil, -- Legacy modem field; prefer autodetect unless explicitly configured.
  reactors = {}, -- Empty list enables auto-discovery for local reactors.
  turbines = {}, -- Empty list enables auto-discovery for local turbines.
  heartbeat_interval = 2, -- Seconds between status heartbeats.
  scan_interval = 10, -- Seconds between peripheral discovery scans.
  startup_watchdog_s = 60, -- Seconds before STARTUP watchdog trips.
  channels = {
    control = constants.channels.CONTROL, -- Control channel for MASTER commands.
    status = constants.channels.STATUS -- Status channel for telemetry.
  },
  comms = {
    ack_timeout_s = 3.0, -- Seconds before retrying a command.
    max_retries = 4, -- Maximum retries per message.
    backoff_base_s = 0.6, -- Base backoff seconds.
    backoff_cap_s = 6.0, -- Max backoff seconds.
    dedupe_ttl_s = 30, -- Seconds to keep dedupe entries.
    dedupe_limit = 200, -- Max dedupe entries per peer.
    peer_timeout_s = 12.0, -- Seconds before marking peer down.
    queue_limit = 200, -- Max queued outbound messages.
    drop_simulation = 0 -- Drop rate (0-1) for testing comms.
  },
  safety = {
    max_temperature = 2000, -- Maximum reactor temperature before SCRAM.
    temperature_hysteresis = 50, -- Temperature margin required before a pending over-limit condition is cleared.
    temperature_trip_samples = 2, -- Consecutive over-limit samples required before SAFE is entered.
    max_rpm = 1800, -- Maximum turbine RPM.
    min_water = 0.2, -- Minimum coolant ratio before SCRAM.
    coolant_hysteresis = 0.05, -- Coolant margin required before a pending low-coolant condition is cleared.
    coolant_trip_samples = 3, -- Consecutive low-coolant samples required before SAFE is entered.
    coolant_invalid_grace_samples = 3 -- Ignore short coolant read glitches before diagnostics mark the sample stream unavailable.
  },
  autonom = {
    control_rod_level = 70, -- Default rod level in autonom mode.
    max_rpm = CONFIG.TARGET_RPM, -- Max RPM in autonom mode.
    min_flow = CONFIG.MIN_FLOW, -- Min flow in autonom mode.
    max_flow = CONFIG.MAX_FLOW, -- Max flow in autonom mode.
    flow_step = CONFIG.FLOW_STEP, -- Flow step in autonom mode.
    ramp_step = CONFIG.FLOW_STEP, -- Ramp step in autonom mode.
    min_rods = CONFIG.ROD_MIN, -- Minimum rod insertion.
    max_rods = CONFIG.ROD_MAX, -- Maximum rod insertion.
    regulator_min_rods = CONFIG.ROD_MIN, -- Lower clamp for automatic rod target.
    regulator_max_rods = CONFIG.ROD_MAX, -- Upper clamp for automatic rod target.
    reactor_adjust_interval = CONFIG.ROD_TICK, -- Reactor adjust interval.
    steam_reserve = 5000, -- Steam reserve threshold.
    steam_deficit = 5000 -- Steam deficit threshold.
  },
  rails = {
    ramp_profiles = {
      NORMAL = { up = 1.0, down = 1.0 },
      SLOW = { up = 0.5, down = 0.5 },
      FAST = { up = 1.5, down = 1.5 }
    },
    turbine_flow = {
      deadband_up = CONFIG.RPM_TOLERANCE, -- RPM deadband before increasing flow.
      deadband_down = CONFIG.RPM_TOLERANCE, -- RPM deadband before decreasing flow.
      hysteresis_up = 10, -- Extra RPM hysteresis for up direction.
      hysteresis_down = 10, -- Extra RPM hysteresis for down direction.
      max_step_up = 250, -- Max flow increase per tick.
      max_step_down = 250, -- Max flow decrease per tick.
      min_step_up = 50, -- Min flow increase when adaptive stepping is active.
      min_step_down = 50, -- Min flow decrease when adaptive stepping is active.
      step_per_rpm_up = 0.5, -- Flow step gain per RPM error (up direction).
      step_per_rpm_down = 0.5, -- Flow step gain per RPM error (down direction).
      adaptive_step = true, -- Enable adaptive step sizing based on RPM error.
      cooldown_s = 0.2, -- Minimum seconds between flow changes.
      settle_timeout_s = 0.8, -- Maximum wait for requested flow to appear in readback before normal cooldown resumes.
      confirm_tolerance = 1, -- Allowed delta between requested and confirmed flow.
      readback_retry_cap = 3, -- Retry cap before cooldown defer is stopped to keep control responsive.
      readback_fast_rereads = 2, -- Immediate re-read attempts after a write to reduce stale readback impact.
      effective_min_samples = 3, -- Readback samples needed before persisting effective min flow.
      target_hold_band_rpm = 30, -- Active holding band around target RPM.
      target_trim_trigger_rpm = 6, -- RPM error threshold for target-band trim corrections.
      target_trim_hold_samples = 2, -- Require repeated in-band confirmations before entering HOLDING_TARGET_ACTIVE.
      target_trim_step_up = 50, -- Fine up-trim step while holding target RPM.
      target_trim_step_down = 75, -- Fine down-trim step while holding target RPM.
      min = CONFIG.MIN_FLOW, -- Flow clamp minimum.
      max = CONFIG.MAX_FLOW, -- Flow clamp maximum.
      ema_alpha = 0.2 -- RPM smoothing alpha.
    },
    reactor_rods = {
      deadband_up = 5000, -- Steam reserve deadband before inserting rods.
      deadband_down = 5000, -- Steam deficit deadband before withdrawing rods.
      hysteresis_up = 500, -- Steam hysteresis for rod insert.
      hysteresis_down = 500, -- Steam hysteresis for rod withdraw.
      max_step_up = CONFIG.REACTOR_STEP, -- Max rod insert step.
      max_step_down = CONFIG.REACTOR_STEP, -- Max rod withdraw step.
      max_apply_step_up = CONFIG.REACTOR_STEP, -- Hard max rod insert delta per control cycle.
      max_apply_step_down = CONFIG.REACTOR_STEP, -- Hard max rod withdraw delta per control cycle.
      cooldown_s = CONFIG.MIN_APPLY_INTERVAL, -- Minimum seconds between rod changes.
      apply_cooldown_s = CONFIG.MIN_APPLY_INTERVAL, -- Minimum seconds between applied rod changes.
      coolant_ramp_soft_limit_ratio = 0.28, -- Soft coolant margin where power-up rod withdraw is damped.
      coolant_ramp_hard_limit_ratio = 0.22, -- Hard coolant margin where power-up rod withdraw is blocked.
      max_step_down_when_coolant_soft = 2, -- Max withdraw step when coolant enters soft-limit zone.
      max_step_down_when_coolant_hard = 0, -- Max withdraw step when coolant enters hard-limit zone.
      min = CONFIG.ROD_MIN, -- Rod clamp minimum.
      max = CONFIG.ROD_MAX, -- Rod clamp maximum.
      ema_alpha = 0.25 -- Steam margin smoothing alpha.
    },
    coil = {
      engage_rpm = CONFIG.COIL_ENGAGE_RPM, -- Coil engage threshold.
      disengage_rpm = CONFIG.COIL_DISENGAGE_RPM, -- Coil disengage threshold.
      cooldown_s = 1.0, -- Minimum seconds between coil changes.
      ema_alpha = 0.2 -- RPM smoothing alpha.
    }
  },
  monitor_interval = 2, -- Monitor update interval (seconds).
  monitor_scale = 0.5, -- Monitor UI scale.
  status_interval = 5, -- Status log interval (seconds).
  status_log = false -- Enable periodic status log output.
}
local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}
local function add_config_warning(message)
  table.insert(config_warnings, message)
end
config_normalizer.validate_config(config, DEFAULT_CONFIG, add_config_warning, utils)
if config.wireless_modem == nil and type(config.modem) == "string" then
  config.wireless_modem = config.modem
  add_config_warning("legacy modem field detected; mapped modem -> wireless_modem")
elseif type(config.modem) == "string" and config.wireless_modem ~= config.modem then
  add_config_warning("legacy modem field ignored because wireless_modem override is set")
end
-- Initialize file logging early to capture startup events.
local node_id = utils.read_node_id(CONFIG.NODE_ID_PATH)
local log_name = utils.build_log_name(CONFIG.LOG_NAME, node_id)
local debug_enabled = config.debug_logging
if CONFIG.DEBUG_LOG_ENABLED ~= nil then
  debug_enabled = CONFIG.DEBUG_LOG_ENABLED
end
if (config_meta and config_meta.reason) or #config_warnings > 0 then
  debug_enabled = true
end
local logger_init_ok, log_status = pcall(utils.init_logger, {
  log_name = log_name,
  prefix = CONFIG.LOG_PREFIX,
  enabled = debug_enabled,
  truncate = config.reset_log_on_start == true
})
if not logger_init_ok then
  print("WARN: RT logger init non-fatal failure: " .. tostring(log_status))
  log_status = { enabled = false, startup_action = "init_nonfatal_failure" }
end
if log_status and log_status.enabled then
  log(INFO, string.format("Logfile %s (startup=%s)", tostring(log_status.log_path), tostring(log_status.startup_action)))
end
log(INFO, "Startup")
if config_meta and config_meta.reason then
  log(WARN, "Config issue (" .. tostring(config_meta.reason) .. ") at " .. tostring(config_meta.path) .. "; using defaults where needed.")
end
for _, warning in ipairs(config_warnings) do
  log(WARN, warning)
end
local TARGET_RPM = CONFIG.TARGET_RPM
local RPM_TOL = CONFIG.RPM_TOLERANCE
local MIN_FLOW = CONFIG.MIN_FLOW
local MAX_FLOW = CONFIG.MAX_FLOW
local FLOW_STEP = CONFIG.FLOW_STEP
local COIL_ENGAGE_RPM = CONFIG.COIL_ENGAGE_RPM
local COIL_DISENG_RPM = CONFIG.COIL_DISENGAGE_RPM
local START_FLOW = CONFIG.START_FLOW
local ROD_TICK = CONFIG.ROD_TICK
local ROD_MIN = CONFIG.ROD_MIN
local ROD_MAX = CONFIG.ROD_MAX
local INITIAL_ROD_LEVEL = CONFIG.INITIAL_ROD_LEVEL
local MIN_APPLY_INTERVAL = CONFIG.MIN_APPLY_INTERVAL
local REACTOR_STEP = CONFIG.REACTOR_STEP
local MIN_ACTIVE_RPM = CONFIG.MIN_ACTIVE_RPM
local last_applied_rods = nil
local last_rod_apply_ts = 0
local last_rod_change_ts = 0
local last_rod_direction = nil
local last_reactor_demand = 0
local steam_tank_name = nil
local reactor_rails_state = rails.new_state()
config.safety = config.safety or {}
config.safety.max_temperature = config.safety.max_temperature or DEFAULT_CONFIG.safety.max_temperature
config.safety.temperature_hysteresis = config.safety.temperature_hysteresis or DEFAULT_CONFIG.safety.temperature_hysteresis
config.safety.temperature_trip_samples = config.safety.temperature_trip_samples or DEFAULT_CONFIG.safety.temperature_trip_samples
config.safety.max_rpm = config.safety.max_rpm or DEFAULT_CONFIG.safety.max_rpm
config.safety.min_water = config.safety.min_water or DEFAULT_CONFIG.safety.min_water
config.safety.coolant_hysteresis = config.safety.coolant_hysteresis or DEFAULT_CONFIG.safety.coolant_hysteresis
config.safety.coolant_trip_samples = config.safety.coolant_trip_samples or DEFAULT_CONFIG.safety.coolant_trip_samples
config.safety.coolant_invalid_grace_samples = config.safety.coolant_invalid_grace_samples or DEFAULT_CONFIG.safety.coolant_invalid_grace_samples
config.heartbeat_interval = config.heartbeat_interval or DEFAULT_CONFIG.heartbeat_interval
config.autonom = config.autonom or {}
config.autonom.control_rod_level = config.autonom.control_rod_level or DEFAULT_CONFIG.autonom.control_rod_level
config.autonom.target_rpm = TARGET_RPM
config.autonom.max_rpm = math.max(config.autonom.max_rpm or TARGET_RPM, TARGET_RPM)
config.autonom.min_flow = math.max(config.autonom.min_flow or MIN_FLOW, MIN_FLOW)
config.autonom.max_flow = math.min(config.autonom.max_flow or MAX_FLOW, MAX_FLOW)
config.autonom.flow_step = config.autonom.flow_step or FLOW_STEP
config.autonom.ramp_step = config.autonom.ramp_step or config.autonom.flow_step
config.autonom.min_rods = config.autonom.min_rods or ROD_MIN
config.autonom.max_rods = config.autonom.max_rods or ROD_MAX
config.autonom.regulator_min_rods = config.autonom.regulator_min_rods or config.autonom.min_rods or DEFAULT_CONFIG.autonom.regulator_min_rods
config.autonom.regulator_max_rods = config.autonom.regulator_max_rods or config.autonom.max_rods or DEFAULT_CONFIG.autonom.regulator_max_rods
config.autonom.reactor_adjust_interval = config.autonom.reactor_adjust_interval or ROD_TICK
config.autonom.steam_reserve = config.autonom.steam_reserve or DEFAULT_CONFIG.autonom.steam_reserve
config.autonom.steam_deficit = config.autonom.steam_deficit or DEFAULT_CONFIG.autonom.steam_deficit
config.rails = config.rails or utils.deep_copy(DEFAULT_CONFIG.rails)
config.rails.ramp_profiles = config.rails.ramp_profiles or utils.deep_copy(DEFAULT_CONFIG.rails.ramp_profiles)
config_normalizer.normalize_rails(config, DEFAULT_CONFIG, utils, safety, MIN_FLOW, MAX_FLOW)
config.monitor_interval = config.monitor_interval or DEFAULT_CONFIG.monitor_interval
config.monitor_scale = config.monitor_scale or DEFAULT_CONFIG.monitor_scale
config.scan_interval = config.scan_interval or DEFAULT_CONFIG.scan_interval
config.startup_watchdog_s = config.startup_watchdog_s or DEFAULT_CONFIG.startup_watchdog_s
local hb = config.heartbeat_interval
local configured_reactors = utils.deep_copy(config.reactors or {})
local configured_turbines = utils.deep_copy(config.turbines or {})
local configured_caps = {
  reactors = #configured_reactors,
  turbines = #configured_turbines
}
local comms
local services
local registry = registry_lib.new({ node_id = node_id, role = "rt", log_prefix = CONFIG.LOG_PREFIX })
local rt_health = health.new({})
local devices = {
  reactors = {},
  turbines = {},
  adapters = { reactors = {}, turbines = {} },
  discovery_failed = false,
  registry_summary = nil,
  registry_load_error = nil,
  proto_mismatch = false,
  binding_signature = nil,
  last_scan_ts = nil,
  discovery_log_signature = nil
}
local master_alerts = {}
local peripherals = { reactors = {}, turbines = {} }
local targets = { power = 0, steam = 0, rpm = TARGET_RPM, enable_reactors = true, enable_turbines = true }
local modules = {}
local active_startup = nil
local startup_queue = {}
local startup_started_ms = nil
local startup_watchdog_tripped = false
local master_seen = os.epoch("utc")
local last_heartbeat = 0
local last_reactor_tick = 0
local last_reactor_debug_log = 0
local status_snapshot = nil
local last_snapshot = 0
local monitor = nil
local monitor_name = nil
local last_actuator_update = 0
local last_command = nil
local last_command_ts = nil
local warned = {}
local autonom_state = { reactors = {}, turbines = {} }
local autonom_control_logged = false
local capability_cache = { reactors = {}, turbines = {} }
local turbine_ctrl = _G.turbine_ctrl or {}
_G.turbine_ctrl = turbine_ctrl
local reactor_ctrl = {}
local cache
local build_modules
local refresh_module_peripherals
local STATE = {
  INIT = "INIT",
  AUTONOM = "AUTONOM",
  MASTER = "MASTER",
  SAFE = "SAFE"
}
local current_state = STATE.INIT
local node_state_machine
local ramp_profiles = {
  FAST = 4000,
  NORMAL = 8000,
  SLOW = 12000
}
local TURBINE_MODE = {
  RAMP = "RAMP",
  REGULATE = "REGULATE"
}
local function get_target_rpm()
  if current_state == STATE.MASTER and type(targets.rpm) == "number" and targets.rpm > 0 then
    return targets.rpm
  end
  return TARGET_RPM
end
local function clamp_turbine_flow(rate)
  return turbine_regulator.clamp_flow(rate, MIN_FLOW, MAX_FLOW)
end
local function clamp_rods(level, allow_overmax)
  if type(level) ~= "number" then
    level = ROD_MAX
  end
  local max_limit = allow_overmax and 100 or ROD_MAX
  return safety.clamp(level, ROD_MIN, max_limit)
end
local function resolve_steam_tank_name()
  if steam_tank_name and peripheral.isPresent(steam_tank_name) then
    return steam_tank_name
  end
  for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name)
    if ptype and string.find(ptype, "ultimate_fluid_tank") then
      steam_tank_name = name
      return steam_tank_name
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if string.find(string.lower(name), "steam") then
      local tank = utils.safe_wrap(name)
      if tank and (tank.tanks or tank.getFluidAmount) then
        steam_tank_name = name
        return steam_tank_name
      end
    end
  end
  return nil
end
local function read_steam_tank_amount()
  local name = resolve_steam_tank_name()
  if not name then
    return nil
  end
  local tank, err = utils.safe_wrap(name)
  if not tank then
    warn_once("steam_tank_wrap:" .. name, "Steam tank wrap failed for " .. name .. ": " .. tostring(err))
    return nil
  end
  local amount, read_err = fluid.read_amount(tank, { "getFluidAmount" })
  if type(amount) == "number" then
    return amount
  end
  warn_once("steam_tank_read:" .. tostring(name), "Steam tank read failed for " .. tostring(name) .. ": " .. tostring(read_err))
  return nil
end
local function read_reactor_steam_amount()
  local total = 0
  local found = false
  for _, name in ipairs(config.reactors or {}) do
    local reactor = peripherals.reactors[name]
    if not reactor then
      local wrapped, err = utils.safe_wrap(name)
      if wrapped then
        reactor = wrapped
      else
        warn_once("reactor_wrap:" .. name, "Reactor wrap failed for " .. name .. ": " .. tostring(err))
      end
    end
    if reactor then
      local amount = nil
      amount = fluid.read_amount(reactor, { "getHotFluidAmount", "getSteamAmount", "getSteam" })
      if type(amount) == "number" then
        total = total + amount
        found = true
      end
    end
  end
  if found then
    return total
  end
  return nil
end
local safe_wrapped_call
local function get_available_steam()
  local tank_amount = read_steam_tank_amount()
  if type(tank_amount) == "number" then
    return tank_amount
  end
  return read_reactor_steam_amount()
end
local function get_total_steam_demand()
  local total = 0
  for _, name in ipairs(config.turbines or {}) do
    local ctrl = get_turbine_ctrl(name)
    local rpm = ctrl.rpm
    if type(rpm) ~= "number" then
      local turbine = peripherals.turbines[name]
      if not turbine then
        local wrapped, err = utils.safe_wrap(name)
        if wrapped then
          turbine = wrapped
        else
          warn_once("turbine_wrap:" .. name, "Turbine wrap failed for " .. name .. ": " .. tostring(err))
        end
      end
      if turbine and turbine.getRotorSpeed then
        local ok, value = safe_wrapped_call(turbine, "getRotorSpeed")
        if ok and type(value) == "number" then
          rpm = value
        end
      end
    end
    if type(rpm) == "number" and rpm > MIN_ACTIVE_RPM then
      total = total + (ctrl.confirmed_flow or ctrl.requested_flow or ctrl.flow or 0)
    end
  end
  return total
end
local function evaluate_reactor_coolant(reactor, state)
  local sample = fluid.read_coolant_sample(reactor, safe_wrapped_call)
  return safety.evaluate_coolant_limit({
    coolant_amount = sample.coolant_amount,
    coolant_amount_max = sample.coolant_amount_max,
    coolant_ratio = sample.coolant_ratio,
    source = sample.source,
    source_method = sample.source_method,
    measurement_state = sample.measurement_state,
    min_water = config.safety.min_water,
    hysteresis = config.safety.coolant_hysteresis,
    trip_samples = config.safety.coolant_trip_samples,
    invalid_grace_samples = config.safety.coolant_invalid_grace_samples,
    zero_glitch_grace_samples = config.safety.coolant_zero_glitch_grace_samples,
    state = state
  })
end
local function ramp_towards(current, target, step)
  if current == nil then return target end
  local delta = target - current
  if math.abs(delta) <= step then
    return target
  end
  if delta > 0 then
    return current + step
  end
  return current - step
end
local function has_method(methods, method)
  for _, name in ipairs(methods or {}) do
    if name == method then
      return true
    end
  end
  return false
end
safe_wrapped_call = function(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(obj[method], ...)
end
local function has_reactor_rod_write_path(caps)
  return caps and (caps.setControlRodsLevels or caps.setAllControlRodLevels or caps.setControlRodLevel or caps.getControlRods)
end
local function build_capabilities(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    methods = {}
  end
  return {
    getActive = has_method(methods, "getActive"),
    setActive = has_method(methods, "setActive"),
    setFluidFlowRate = has_method(methods, "setFluidFlowRate"),
    setFluidFlowRateMax = has_method(methods, "setFluidFlowRateMax"),
    getFluidFlowRate = has_method(methods, "getFluidFlowRate"),
    getFluidFlowRateMax = has_method(methods, "getFluidFlowRateMax"),
    getFluidFlowRateMaxMax = has_method(methods, "getFluidFlowRateMaxMax"),
    getRotorSpeed = has_method(methods, "getRotorSpeed"),
    getRotorRPM = has_method(methods, "getRotorRPM"),
    getControlRods = has_method(methods, "getControlRods"),
    getControlRodLevel = has_method(methods, "getControlRodLevel"),
    getControlRodLevels = has_method(methods, "getControlRodLevels"),
    getControlRodsLevels = has_method(methods, "getControlRodsLevels"),
    getInductorEngaged = has_method(methods, "getInductorEngaged"),
    setInductorEngaged = has_method(methods, "setInductorEngaged"),
    setAllControlRodLevels = has_method(methods, "setAllControlRodLevels"),
    setControlRodsLevels = has_method(methods, "setControlRodsLevels"),
    setControlRodLevel = has_method(methods, "setControlRodLevel")
  }
end
local function read_turbine_rpm(turbine, caps)
  if not turbine then
    return nil, "NO_TURBINE"
  end
  if caps and caps.getRotorSpeed and turbine.getRotorSpeed then
    local ok, value = safe_wrapped_call(turbine, "getRotorSpeed")
    if ok and type(value) == "number" then
      return value, "getRotorSpeed"
    end
  end
  if caps and caps.getRotorRPM and turbine.getRotorRPM then
    local ok, value = safe_wrapped_call(turbine, "getRotorRPM")
    if ok and type(value) == "number" then
      return value, "getRotorRPM"
    end
  end
  return nil, "RPM_UNAVAILABLE"
end
local function read_turbine_flow(turbine, caps)
  if not turbine then
    return nil, "NO_TURBINE"
  end
  if caps and caps.getFluidFlowRateMax and turbine.getFluidFlowRateMax then
    local ok, value = safe_wrapped_call(turbine, "getFluidFlowRateMax")
    if ok and type(value) == "number" then
      return value, "getFluidFlowRateMax"
    end
  end
  if caps and caps.getFluidFlowRate and turbine.getFluidFlowRate then
    local ok, value = safe_wrapped_call(turbine, "getFluidFlowRate")
    if ok and type(value) == "number" then
      return value, "getFluidFlowRate"
    end
  end
  return nil, "FLOW_UNAVAILABLE"
end
local function init_turbine_ctrl()
  for key in pairs(turbine_ctrl) do
    turbine_ctrl[key] = nil
  end
  autonom_state.turbines = turbine_ctrl
  local turbines = config.turbines or {}
  log("INFO", "Detected " .. tostring(#turbines) .. " turbines")
  if #turbines < 1 then
    log("ERROR", binding.missing_devices_message("turbine", binding.build_policy(configured_reactors, configured_turbines)))
    return
  end
  for _, name in ipairs(turbines) do
    local ctrl = get_turbine_ctrl(name)
    ctrl.flow = clamp_turbine_flow(START_FLOW)
    ctrl.requested_flow = ctrl.flow
    ctrl.confirmed_flow = ctrl.flow
    ctrl.pending_flow_since = 0
    ctrl.pending_expected_flow = ctrl.flow
    ctrl.pending_retries = 0
    ctrl.effective_min_hits = 0
    ctrl.effective_min_flow = nil
    ctrl.effective_max_flow = nil
    ctrl.startup_synced = false
    ctrl.mode = TURBINE_MODE.RAMP
    ctrl.logged = false
    log("INFO", "Controlling turbine: " .. name)
  end
end
local function get_device_caps(kind, name)
  capability_cache[kind] = capability_cache[kind] or {}
  if not capability_cache[kind][name] or peripheral.isPresent(name) then
    capability_cache[kind][name] = build_capabilities(name)
  end
  return capability_cache[kind][name]
end
local function setReactorActive(reactor, caps, active)
  if caps.setActive then
    reactor.setActive(active)
    return true
  end
  return false
end
local function setTurbineFlow(turbine, caps, rate)
  local clamped = clamp_turbine_flow(rate)
  if caps.setFluidFlowRate or type(turbine.setFluidFlowRate) == "function" then
    if caps then
      caps.setFluidFlowRate = true
    end
    turbine.setFluidFlowRate(clamped)
    return true, "setFluidFlowRate"
  elseif caps.setFluidFlowRateMax or type(turbine.setFluidFlowRateMax) == "function" then
    if caps then
      caps.setFluidFlowRateMax = true
    end
    turbine.setFluidFlowRateMax(clamped)
    return true, "setFluidFlowRateMax"
  end
  return false, "NO_FLOW_API"
end
local function setInductor(turbine, caps, engaged)
  if caps.setInductorEngaged then
    turbine.setInductorEngaged(engaged)
    return true
  end
  return false
end
local function setTurbineActive(turbine, caps, active)
  if caps.setActive then
    turbine.setActive(active)
    return true
  end
  return true
end
local function ensure_reactor_ctrl(name)
  local ctrl = reactor_ctrl[name]
  if not ctrl then
    ctrl = { last_steam_pct = nil, last_applied = nil, last_adjust = 0, initialized = false }
    reactor_ctrl[name] = ctrl
  end
  return ctrl
end
local function init_reactor_ctrl()
  reactor_ctrl = {}
  for _, name in ipairs(config.reactors or {}) do
    reactor_ctrl[name] = {
      last_steam_pct = nil,
      last_applied = nil,
      last_adjust = 0,
      initialized = false
    }
  end
end
function applyReactorRods(target, allow_overmax)
  local now = os.clock()
  if now - last_rod_apply_ts < MIN_APPLY_INTERVAL then
    return false
  end
  if type(target) ~= "number" then
    return false
  end
  local clamped = clamp_rods(target, allow_overmax)
  if last_applied_rods == clamped then
    autonom_state.pending_rod_direction = nil
    return false
  end
  local applied = false
  for name, ctrl in pairs(reactor_ctrl) do
    local ok_apply, err_apply = reactor_adapter.apply_rod_level(name, clamped, CONFIG.LOG_PREFIX)
    if ok_apply then
      ctrl.last_applied = clamped
      ctrl.last_known_rods = clamped
      applied = true
    else
      warn_once("reactor_rods:" .. name, "Reactor control rod write failed for " .. tostring(name) .. ": " .. tostring(err_apply))
    end
  end
  if not applied then
    return false
  end
  local previous_applied = last_applied_rods
  last_applied_rods = clamped
  last_rod_apply_ts = now
  local applied_direction = autonom_state.pending_rod_direction
  if applied_direction == nil and type(previous_applied) == "number" then
    if clamped < previous_applied then
      applied_direction = "DOWN"
    elseif clamped > previous_applied then
      applied_direction = "UP"
    end
  end
  if applied_direction ~= nil then
    last_rod_change_ts = now
    last_rod_direction = applied_direction
  end
  autonom_state.pending_rod_direction = nil
  log("INFO", "Applied rods " .. tostring(clamped) .. "%")
  return true
end
local function apply_initial_reactor_rods()
  for name, ctrl in pairs(reactor_ctrl) do
    ctrl.last_applied = nil
    log("INFO", "Reactor " .. name .. " initial rods set to " .. tostring(INITIAL_ROD_LEVEL) .. "%")
  end
  applyReactorRods(INITIAL_ROD_LEVEL, false)
end
local function read_current_rods()
  for _, name in ipairs(config.reactors or {}) do
    local current_rods = reactor_adapter.read_control_rods(name, CONFIG.LOG_PREFIX)
    if type(current_rods) == "number" then
      local ctrl = ensure_reactor_ctrl(name)
      ctrl.last_known_rods = current_rods
      return current_rods
    end
    local ctrl = reactor_ctrl[name]
    if ctrl and type(ctrl.last_known_rods) == "number" then
      return ctrl.last_known_rods
    end
  end
  return nil
end
local function log_reactor_control_state()
  local now = os.clock()
  if now - last_reactor_debug_log < 5 then
    return
  end
  last_reactor_debug_log = now
  local sample_rods = read_current_rods() or last_applied_rods or "n/a"
  local tick_age = now - last_reactor_tick
  log("DEBUG", "ReactorCtrl state=" .. tostring(current_state) .. " rods=" .. tostring(sample_rods) .. " ticks=" .. string.format("%.1f", tick_age) .. "s")
end
local function log_reactor_control_tick()
  local sample_demand = last_reactor_demand
  local age = os.clock() - last_rod_change_ts
  log(
    "DEBUG",
    "ReactorCtrl demand="
      .. tostring(sample_demand)
      .. " dir="
      .. tostring(last_rod_direction)
      .. " age="
      .. string.format("%.1f", age)
  )
  log("INFO", "ReactorCtrl demand=" .. tostring(sample_demand))
end
local function controlReactor()
  local turbine_count = #config.turbines
  if turbine_count == 0 then
    return
  end
  local total_steam_demand = get_total_steam_demand()
  local available_steam = get_available_steam()
  if type(available_steam) ~= "number" then
    return
  end
  local steam_margin = available_steam - total_steam_demand
  last_reactor_demand = steam_margin
  local current_rods = read_current_rods()
  if type(current_rods) ~= "number" then
    log("ERROR", "Reactor control rods unreadable")
    return
  end
  local rod_cfg = config.rails and config.rails.reactor_rods or {}
  local smoothed_margin = rails.smooth(reactor_rails_state, "steam_margin", steam_margin, rod_cfg.ema_alpha)
  local target_rods, direction = rails.step(current_rods, smoothed_margin, reactor_rails_state, rod_cfg, os.clock())
  target_rods = safety.clamp(target_rods, ROD_MIN, ROD_MAX)
  do
    local cfg_min = config.autonom and config.autonom.regulator_min_rods or ROD_MIN
    local cfg_max = config.autonom and config.autonom.regulator_max_rods or ROD_MAX
    local clamped_target, clamp_reason = rails.clamp_with_reason(target_rods, cfg_min, cfg_max)
    if clamp_reason == "MIN" then
      log("DEBUG", "ROD_TARGET_CLAMPED_BY_CONFIG_MIN current=" .. tostring(current_rods) .. " target=" .. tostring(target_rods) .. " clamped=" .. tostring(clamped_target) .. " cfg_min=" .. tostring(cfg_min) .. " cfg_max=" .. tostring(cfg_max))
    elseif clamp_reason == "MAX" then
      log("DEBUG", "ROD_TARGET_CLAMPED_BY_CONFIG_MAX current=" .. tostring(current_rods) .. " target=" .. tostring(target_rods) .. " clamped=" .. tostring(clamped_target) .. " cfg_min=" .. tostring(cfg_min) .. " cfg_max=" .. tostring(cfg_max))
    end
    target_rods = clamped_target
  end
  local min_coolant_ratio
  for _, name in ipairs(config.reactors or {}) do
    local reactor, sample = peripherals.reactors[name], nil
    if reactor then sample = fluid.read_coolant_sample(reactor, safe_wrapped_call) end
    local ratio = sample and sample.coolant_ratio or nil
    if type(ratio) == "number" and (min_coolant_ratio == nil or ratio < min_coolant_ratio) then min_coolant_ratio = ratio end
  end
  local applied_rods, ramp_diag = rails.ramp_target(current_rods, target_rods, rod_cfg, { state = reactor_rails_state, now = os.clock(), coolant_ratio = min_coolant_ratio, safety_min_water = config.safety and config.safety.min_water })
  applied_rods = safety.clamp(applied_rods, ROD_MIN, ROD_MAX)
  if applied_rods == current_rods then
    if ramp_diag and ramp_diag.reason == "RAMP_APPLIED" then log("DEBUG", "ROD_RAMP_APPLIED requested_delta=" .. tostring(ramp_diag.requested_delta) .. " applied_delta=" .. tostring(ramp_diag.applied_delta) .. " current=" .. tostring(current_rods) .. " target=" .. tostring(target_rods)) end
    return
  end
  if direction ~= 0 then
    autonom_state.pending_rod_direction = direction > 0 and "UP" or "DOWN"
  end
  local applied = applyReactorRods(applied_rods, false)
  if applied then
    local limited = ramp_diag and math.abs(tonumber(ramp_diag.applied_delta) or 0) < math.abs(tonumber(ramp_diag.requested_delta) or 0)
    log("INFO", string.format("ReactorCtrl margin=%.1f rods_current=%.1f rods_target=%.1f requested_delta=%.1f applied_delta=%.1f ramp_reason=%s rate_limited=%s coolant_ratio=%s coolant_limited=%s", steam_margin, current_rods, target_rods, (ramp_diag and ramp_diag.requested_delta) or 0, (ramp_diag and ramp_diag.applied_delta) or (applied_rods - current_rods), tostring(ramp_diag and ramp_diag.reason or "n/a"), tostring(limited), tostring(min_coolant_ratio), tostring(ramp_diag and ramp_diag.coolant_limited == true)))
    if limited then log("DEBUG", "ROD_TARGET_CLAMPED_BY_RATE_LIMIT current=" .. tostring(current_rods) .. " target=" .. tostring(target_rods) .. " requested_delta=" .. tostring(ramp_diag.requested_delta) .. " applied_delta=" .. tostring(ramp_diag.applied_delta) .. " max_step=" .. tostring(ramp_diag.max_step)) end
    if ramp_diag and ramp_diag.coolant_limited then
      log("DEBUG", "ROD_CHANGE_LIMITED_BY_COOLANT_MARGIN ratio=" .. tostring(min_coolant_ratio) .. " mode=" .. tostring(ramp_diag.coolant_reason) .. " requested_delta=" .. tostring(ramp_diag.requested_delta) .. " applied_delta=" .. tostring(ramp_diag.applied_delta))
    end
  end
end
local function updateReactorControl()
  local now = os.clock()
  log("DEBUG", "Reactor control tick")
  if current_state == STATE.SAFE then
    applyReactorRods(ROD_MAX, true)
    return
  end
  if now - last_reactor_tick < config.autonom.reactor_adjust_interval then
    return
  end
  last_reactor_tick = now
  log_reactor_control_state()
  controlReactor()
  log_reactor_control_tick()
end
function warn_once(key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  log("WARN", message)
end
local function warn_unsupported(name, reason)
  local suffix = reason and (" (" .. tostring(reason) .. ")") or ""
  warn_once("device_unsupported:" .. name .. ":" .. tostring(reason or "generic"), "Device unsupported by API: " .. name .. suffix)
end
local function turbine_has_flow_setter(turbine, caps)
  if caps and (caps.setFluidFlowRate or caps.setFluidFlowRateMax) then
    return true, "capability-cache"
  end
  if turbine and type(turbine.setFluidFlowRate) == "function" then
    if caps then
      caps.setFluidFlowRate = true
    end
    return true, "runtime-probe:setFluidFlowRate"
  end
  if turbine and type(turbine.setFluidFlowRateMax) == "function" then
    if caps then
      caps.setFluidFlowRateMax = true
    end
    return true, "runtime-probe:setFluidFlowRateMax"
  end
  return false, "missing-flow-setter"
end
local function read_turbine_inductor_state(turbine, caps)
  if turbine and caps and caps.getInductorEngaged and turbine.getInductorEngaged then
    local ok, value = safe_wrapped_call(turbine, "getInductorEngaged")
    if ok and type(value) == "boolean" then return value, "getInductorEngaged" end
  end
  return nil, "INDUCTOR_UNAVAILABLE"
end
local function update_inductor_for_rpm(name, turbine, caps, rpm)
  local ctrl = get_turbine_ctrl(name)
  local measured_inductor, measured_api = read_turbine_inductor_state(turbine, caps)
  if type(measured_inductor) == "boolean" then
    ctrl.inductor_engaged = measured_inductor
    ctrl.inductor_state_api = measured_api
  elseif ctrl.inductor_engaged == nil then
    ctrl.inductor_engaged = false
  end
  local coil_cfg = config.rails and config.rails.coil or {}
  local state = ctrl.rails and ctrl.rails.coil or rails.new_state()
  if ctrl.rails then
    ctrl.rails.coil = state
  end
  local smoothed_rpm = rails.smooth(state, "rpm", rpm, coil_cfg.ema_alpha)
  local engaged = ctrl.inductor_engaged or false
  local now = os.clock()
  local cooldown = coil_cfg.cooldown_s or 0
  if cooldown > 0 and now - (state.last_change_ts or 0) < cooldown then
    return true, true
  end
  local engage_rpm = coil_cfg.engage_rpm or COIL_ENGAGE_RPM
  local disengage_rpm = coil_cfg.disengage_rpm or COIL_DISENG_RPM
  if smoothed_rpm and smoothed_rpm >= engage_rpm and not engaged then
    engaged = true
  elseif (not smoothed_rpm or smoothed_rpm <= disengage_rpm) and engaged then
    engaged = false
  end
  if engaged == ctrl.inductor_engaged then
    return true, true, measured_api
  end
  if not caps.setInductorEngaged then
    ctrl.inductor_engaged = engaged
    return true, true, "inductor-write-unavailable"
  end
  ctrl.inductor_engaged = engaged
  state.last_change_ts = now
  local ok, applied = pcall(setInductor, turbine, caps, engaged)
  if ok and applied then
    local reason = "TARGET_TRACKING"
    if ctrl.mode == "OVERSPEED_BRAKE" then
      reason = "OVERSPEED_BRAKE"
    end
    ctrl.last_coil_reason = reason
    log("INFO", ("Turbine coil name=%s engaged=%s reason=%s rpm=%s"):format(
      tostring(name),
      tostring(engaged),
      tostring(reason),
      tostring(rpm)
    ))
  end
  return ok, applied, measured_api
end
local function update_turbine_flow_state(rpm, target_rpm, ctrl)
  local rail_cfg = config.rails and config.rails.turbine_flow or {}
  local flow_state = ctrl.rails and ctrl.rails.flow or rails.new_state()
  if ctrl.rails then
    ctrl.rails.flow = flow_state
  end
  local now_ts = os.clock()
  local smoothed_rpm = rails.smooth(flow_state, "rpm", rpm, rail_cfg.ema_alpha)
  local target = target_rpm or TARGET_RPM
  local error = target - (smoothed_rpm or target)
  rail_cfg.ramp_profile = ctrl.ramp_profile or rail_cfg.ramp_profile or "NORMAL"
  local base_flow = ctrl.requested_flow or ctrl.flow or 0
  local flow_cfg = rail_cfg
  local min_flow, min_from_effective = turbine_regulator.resolve_min_flow(rail_cfg.min or MIN_FLOW, ctrl.effective_min_flow)
  local max_flow = rail_cfg.max or MAX_FLOW
  if type(ctrl.effective_max_flow) == "number" then
    max_flow = math.min(max_flow, ctrl.effective_max_flow)
  end
  if min_from_effective then
    flow_cfg = utils.deep_copy(flow_cfg)
    flow_cfg.min = min_flow
  end
  if max_flow ~= (rail_cfg.max or MAX_FLOW) then
    if flow_cfg == rail_cfg then
      flow_cfg = utils.deep_copy(flow_cfg)
    end
    flow_cfg.max = max_flow
  end
  local pending_requested_flow = ctrl.pending_expected_flow
  if type(pending_requested_flow) ~= "number" then
    pending_requested_flow = ctrl.requested_flow
  end
  local defer_cooldown, defer_reason = turbine_regulator.should_defer_cooldown(
    pending_requested_flow,
    ctrl.confirmed_flow,
    ctrl.pending_flow_since,
    now_ts,
    rail_cfg.settle_timeout_s,
    rail_cfg.confirm_tolerance,
    ctrl.pending_retries,
    rail_cfg.readback_retry_cap
  )
  if defer_cooldown then
    flow_cfg = utils.deep_copy(rail_cfg)
    flow_cfg.cooldown_s = 0
  end
  local next_flow, direction, decision = rails.step(base_flow, error, flow_state, flow_cfg, now_ts)
  local hold_band = rail_cfg.target_hold_band_rpm or rail_cfg.deadband_up or RPM_TOLERANCE
  local trim_trigger = math.max(0, rail_cfg.target_trim_trigger_rpm or 6)
  local overspeed_state = turbine_regulator.overspeed_brake_state({
    rpm = smoothed_rpm or rpm or target,
    live_rpm = rpm,
    target_rpm = target,
    requested_flow = base_flow,
    max_flow = max_flow,
    band_rpm = hold_band
  })
  if overspeed_state.active then
    next_flow = 0
    direction = -1
    decision = {
      reason = "OVERSPEED_BRAKE_FLOW_ZERO",
      step = math.abs(base_flow),
      min = 0,
      max = max_flow,
      overspeed_brake = true,
      overspeed_rpm = overspeed_state.overspeed_rpm,
      overspeed_threshold_rpm = overspeed_state.threshold_rpm,
      target_band = false,
      target_band_mode = "OVERSPEED_BRAKE"
    }
  end
  local target_band = turbine_regulator.target_band_state({
    rpm = smoothed_rpm or rpm or target,
    live_rpm = rpm,
    target_rpm = target,
    requested_flow = base_flow,
    confirmed_flow = ctrl.confirmed_flow,
    min_flow = min_flow,
    max_flow = max_flow,
    coil_engaged = ctrl.inductor_engaged,
    band_rpm = hold_band,
    trim_trigger_rpm = trim_trigger,
    trim_up_step = rail_cfg.target_trim_step_up or 50,
    trim_down_step = rail_cfg.target_trim_step_down or 75
  })
  if (not overspeed_state.active) and target_band and target_band.in_band then
    next_flow = target_band.flow
    direction = target_band.direction or 0
    decision = {
      reason = target_band.reason,
      step = math.abs((target_band.flow or base_flow) - base_flow),
      min = min_flow,
      max = max_flow,
      target_band = true,
      target_band_mode = target_band.mode,
      target_band_error = target_band.error,
      target_band_live_error = target_band.live_error,
      target_band_smoothed_error = target_band.smoothed_error,
      target_band_at_min_limit = target_band.at_min_limit == true,
      target_band_at_max_limit = target_band.at_max_limit == true
    }
    local confirmed_at_max = type(ctrl.confirmed_flow) == "number" and ctrl.confirmed_flow >= (max_flow - 1)
    local requested_at_max = type(base_flow) == "number" and base_flow >= (max_flow - 1)
    local trimmed_flow = turbine_regulator.clamp_flow(base_flow - math.max(1, rail_cfg.target_trim_step_down or 50), min_flow, max_flow)
    local can_force_trim = (requested_at_max or confirmed_at_max)
      and direction == 0
      and (target_band.error or 0) <= trim_trigger
      and trimmed_flow < base_flow
    if can_force_trim then
      next_flow = trimmed_flow
      direction = -1
      decision.reason = "TARGET_TRIM_DOWN"
      decision.step = math.abs(next_flow - base_flow)
      decision.target_band_mode = "TARGET_TRIM_DOWN"
      decision.target_band_at_min_limit = next_flow <= min_flow
      decision.target_band_at_max_limit = next_flow >= max_flow
    end
  elseif (not overspeed_state.active) and decision and decision.reason == "DEADBAND" and base_flow >= (max_flow - 1) then
    local emergency_trim = math.max(1, rail_cfg.target_trim_step_down or 50)
    local live_error = target - (rpm or target)
    local can_trim = math.abs(live_error) <= hold_band
      or (live_error <= trim_trigger and live_error >= (-hold_band))
    next_flow = can_trim and turbine_regulator.clamp_flow(base_flow - emergency_trim, min_flow, max_flow) or base_flow
    direction = next_flow < base_flow and -1 or 0
    decision = {
      reason = next_flow < base_flow and "TARGET_TRIM_DOWN" or "MAX_LIMIT_UNDERSPEED",
      step = math.abs(next_flow - base_flow),
      min = min_flow,
      max = max_flow,
      target_band = true,
      target_band_mode = next_flow < base_flow and "TARGET_TRIM_DOWN" or "MAX_LIMIT_UNDERSPEED",
      target_band_error = live_error,
      target_band_live_error = live_error,
      target_band_smoothed_error = target - (smoothed_rpm or target),
      target_band_at_min_limit = next_flow <= min_flow,
      target_band_at_max_limit = next_flow >= max_flow
    }
  end
  ctrl.requested_flow = clamp_turbine_flow(next_flow)
  ctrl.flow = ctrl.requested_flow
  if defer_cooldown and decision then
    decision.defer_cooldown = true
    decision.defer_reason = defer_reason
  end
  local hold_sample_target = math.max(1, rail_cfg.target_trim_hold_samples or 2)
  if (not overspeed_state.active) and target_band and target_band.in_band and target_band.mode == "HOLDING_TARGET_ACTIVE" then
    ctrl.target_hold_hits = (ctrl.target_hold_hits or 0) + 1
  else
    ctrl.target_hold_hits = 0
  end
  ctrl.target_holding_active = (not overspeed_state.active)
    and target_band
    and target_band.in_band
    and target_band.mode == "HOLDING_TARGET_ACTIVE"
    and ctrl.target_hold_hits >= hold_sample_target
    or false
  ctrl.target_trim_active = (not overspeed_state.active)
    and target_band
    and target_band.in_band
    and (target_band.mode == "TARGET_TRIM_UP" or target_band.mode == "TARGET_TRIM_DOWN")
    or false
  ctrl.in_target_band = (not overspeed_state.active) and target_band and target_band.in_band or false
  ctrl.target_band_status = overspeed_state.active and "OVERSPEED_BRAKE" or (target_band and target_band.mode or "TRACKING")
  if ctrl.target_holding_active and type(ctrl.target_band_status) == "string" then
    ctrl.mode = ctrl.target_band_status
  elseif overspeed_state.active then
    ctrl.mode = "OVERSPEED_BRAKE"
  elseif direction > 0 then
    ctrl.mode = "UP"
  elseif direction < 0 then
    ctrl.mode = "DOWN"
  elseif decision and decision.reason == "DEADBAND" then
    ctrl.mode = "TRACKING_DEADBAND"
  else
    ctrl.mode = "TRACKING_STABLE"
  end
  return ctrl.requested_flow, ctrl.mode, decision, smoothed_rpm
end
local function enforce_overspeed_brake_coil(name, turbine, caps, ctrl, decision)
  if type(decision) ~= "table" or decision.overspeed_brake ~= true then
    return true, "not-required"
  end
  if ctrl.inductor_engaged == true then
    return true, "already-engaged"
  end
  if not (caps and caps.setInductorEngaged) then
    ctrl.inductor_engaged = true
    return false, "inductor-write-unavailable"
  end
  local ok, applied = pcall(setInductor, turbine, caps, true)
  if ok and applied then
    ctrl.inductor_engaged = true
    return true, "overspeed-coil-engaged"
  end
  return false, "overspeed-coil-set-failed:" .. tostring(applied)
end

local function apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
  local ctrl = get_turbine_ctrl(name)
  if type(rpm) == "number" then
    ctrl.rpm = rpm
  end
  if type(ctrl.effective_max_flow) ~= "number" and caps and caps.getFluidFlowRateMaxMax and turbine.getFluidFlowRateMaxMax then
    local max_ok, max_value = safe_wrapped_call(turbine, "getFluidFlowRateMaxMax")
    if max_ok and type(max_value) == "number" and max_value > 0 then
      ctrl.effective_max_flow = math.min(MAX_FLOW, math.max(MIN_FLOW, math.floor(max_value + 0.5)))
    end
  end
  local startup_observed_flow, startup_reader = read_turbine_flow(turbine, caps)
  if type(startup_observed_flow) == "number" then
    local synced = clamp_turbine_flow(startup_observed_flow)
    ctrl.confirmed_flow = synced
    if not ctrl.startup_synced and turbine_regulator.sync_startup_state(ctrl, synced) then
      log("DEBUG", "TurbineSync name=" .. name
          .. " source=confirmed_flow"
          .. " synced_flow=" .. tostring(synced)
          .. " flow_api=" .. tostring(startup_reader)
          .. " effective_min_flow=" .. tostring(ctrl.effective_min_flow))
      return true, false, "startup-sync-hold", "STARTUP_SYNC"
    end
  end
  local old_flow = ctrl.confirmed_flow or ctrl.requested_flow or ctrl.flow
  local requested_flow, mode, decision, smoothed_rpm = update_turbine_flow_state(rpm, target_rpm, ctrl)
  local steam_input, active_state = flow_apply_helpers.sample_turbine_runtime_metrics(turbine, caps, safe_wrapped_call)
  local now_ts = os.clock()
  local ok, applied, setter = pcall(setTurbineFlow, turbine, caps, requested_flow)
  local overspeed_coil_ok, overspeed_coil_reason = enforce_overspeed_brake_coil(name, turbine, caps, ctrl, decision)
  local rail_cfg = config.rails and config.rails.turbine_flow or {}
  local observed_flow, flow_reader, attempt, flow_tolerance =
    flow_apply_helpers.capture_turbine_flow_readback(turbine, caps, ctrl, requested_flow, rail_cfg, read_turbine_flow, clamp_turbine_flow)
  local confirmed_flow = ctrl.confirmed_flow
  local flow_settled = turbine_regulator.flows_match(requested_flow, confirmed_flow, flow_tolerance)
  local pending_settled, effective_min_flow, effective_min_changed, readback_state, readback_detail =
    flow_apply_helpers.update_turbine_flow_tracking(ctrl, requested_flow, confirmed_flow, flow_tolerance, rail_cfg, now_ts, decision, turbine_regulator)
  ctrl.last_requested_flow = requested_flow
  local direction = mode
  local reason = decision and decision.reason or "NONE"
  local step = decision and decision.step or "nil"
  local applied_min = decision and decision.min or rail_cfg.min
  local applied_max = decision and decision.max or rail_cfg.max
  local bottleneck, bottleneck_detail = turbine_regulator.classify_bottleneck({
    requested_flow = requested_flow,
    confirmed_flow = confirmed_flow,
    rpm = rpm,
    target_rpm = target_rpm,
    min_flow = applied_min,
    max_flow = ctrl.effective_max_flow or MAX_FLOW,
    inductor_engaged = ctrl.inductor_engaged,
    steam_input = steam_input
  })
  local target_zone_state = ctrl.in_target_band and "IN_TARGET_BAND" or "OUTSIDE_TARGET_BAND"
  local target_action = flow_apply_helpers.resolve_target_action(reason, decision)
  if ctrl.target_holding_active then
    target_action = "TARGET_HOLD_STABLE"
  elseif ctrl.target_trim_active then
    target_action = decision and decision.target_band_mode or target_action
  end
  local at_max_limit = requested_flow == (ctrl.effective_max_flow or MAX_FLOW)
  local at_min_limit = type(applied_min) == "number" and requested_flow <= applied_min
  local active_trim = ctrl.target_trim_active or target_action == "TARGET_TRIM_UP" or target_action == "TARGET_TRIM_DOWN"
  local hold_active = ctrl.target_holding_active and target_action == "TARGET_HOLD_STABLE"
  if active_trim and readback_state == "READBACK_LAG" then
    target_action = "ACTIVE_TRIM_WITH_READBACK_LAG"
  elseif active_trim and readback_state == "PENDING_MISMATCH" then
    target_action = "TRIM_PENDING_CONFIRMATION"
  elseif hold_active and readback_state == "CONFIRMED_MATCH" then
    target_action = "HOLD_CONFIRMED"
  end
  local down_limited = tostring(reason):find("MIN_LIMIT_OVERSPEED", 1, true) ~= nil
  local up_limited = tostring(reason):find("MAX_LIMIT_UNDERSPEED", 1, true) ~= nil
  ctrl.target_trim_state = active_trim and (decision and decision.target_band_mode or "ACTIVE_TRIM") or "NONE"
  if down_limited or (decision and decision.target_band_at_min_limit) then
    ctrl.flow_limit_state = "MIN_LIMIT"
  elseif up_limited or (decision and decision.target_band_at_max_limit) then
    ctrl.flow_limit_state = "MAX_LIMIT"
  else
    ctrl.flow_limit_state = "NONE"
  end
  flow_apply_helpers.log_turbine_control_metrics({
    name = name,
    rpm = rpm,
    smoothed_rpm = smoothed_rpm,
    target_rpm = target_rpm,
    old_flow = old_flow,
    requested_flow = requested_flow,
    confirmed_flow = confirmed_flow,
    direction = direction,
    reason = reason,
    step = step,
    applied_min = applied_min,
    applied_max = applied_max,
    setter = setter,
    set_called = ok and applied,
    set_ok = ok,
    observed_flow = observed_flow,
    flow_reader = flow_reader,
    attempt = attempt,
    flow_settled = flow_settled,
    pending_settled = pending_settled,
    pending_retries = ctrl.pending_retries,
    pending_flow_since = ctrl.pending_flow_since,
    pending_expected_flow = ctrl.pending_expected_flow,
    cooldown_deferred = decision and decision.defer_cooldown or false,
    cooldown_defer_reason = decision and decision.defer_reason or "n/a",
    effective_min_flow = effective_min_flow,
    effective_min_applied = type(effective_min_flow) == "number" and requested_flow == effective_min_flow and requested_flow > 0,
    mode = mode,
    target_action = target_action,
    target_zone_state = target_zone_state,
    target_holding_active = ctrl.target_holding_active,
    target_band_status = ctrl.target_band_status,
    target_band_reason = decision and decision.target_band_mode or "n/a",
    target_band_error = decision and decision.target_band_error or "n/a",
    target_band_live_error = decision and decision.target_band_live_error or "n/a",
    target_band_smoothed_error = decision and decision.target_band_smoothed_error or "n/a",
    hold_active = hold_active,
    active_trim = active_trim,
    flow_trim_direction = active_trim and (target_action == "TARGET_TRIM_UP" and "UP" or "DOWN") or "NONE",
    inductor_engaged = ctrl.inductor_engaged,
    inductor_state_api = ctrl.inductor_state_api or "n/a",
    overspeed_brake = decision and decision.overspeed_brake or false,
    overspeed_rpm = decision and decision.overspeed_rpm or "n/a",
    overspeed_threshold_rpm = decision and decision.overspeed_threshold_rpm or "n/a",
    overspeed_coil_ok = overspeed_coil_ok,
    overspeed_coil_reason = overspeed_coil_reason,
    overspeed_floor_hits = ctrl.overspeed_floor_hits or 0,
    readback_state = readback_state,
    readback_detail = readback_detail,
    steam_input = steam_input,
    active_state = active_state,
    max_flow_limit = ctrl.effective_max_flow or MAX_FLOW,
    at_max_limit = at_max_limit,
    at_min_limit = at_min_limit,
    down_regulation_limited = down_limited or (decision and decision.target_band_at_min_limit) or false,
    up_regulation_limited = up_limited or (decision and decision.target_band_at_max_limit) or false,
    flow_limit_state = ctrl.flow_limit_state,
    bottleneck = bottleneck,
    bottleneck_detail = bottleneck_detail
  }, log)
  if not ctrl.logged then
    log("INFO", "Turbine " .. name .. " active, initial flow " .. tostring(ctrl.requested_flow))
    ctrl.logged = true
  end
  if requested_flow == 0 and type(effective_min_flow) == "number" and effective_min_changed then
    log("INFO", "Turbine " .. name .. " effective minimum flow detected at " .. tostring(effective_min_flow))
  end
  if decision and decision.overspeed_brake and requested_flow == 0 and type(confirmed_flow) == "number" and confirmed_flow > flow_tolerance then
    log("WARN", ("Overspeed brake pending name=%s requested_flow=0 confirmed_flow=%s readback_state=%s detail=%s retries=%s"):format(
      tostring(name),
      tostring(confirmed_flow),
      tostring(readback_state),
      tostring(readback_detail),
      tostring(ctrl.pending_retries)
    ))
  end
  if not ok then
    return false, applied, setter, "FLOW_SET_CALL_FAILED"
  end
  if not applied then
    return true, false, setter, "FLOW_SET_SKIPPED"
  end
  return true, true, setter, "FLOW_SET_OK"
end
local set_reactors_active
local set_turbines_active
local apply_safe_controls
local function updateActuators()
  if current_state ~= STATE.AUTONOM then
    return
  end
  for _, name in ipairs(config.reactors) do
    local reactor
    if peripheral.isPresent(name) then
      local wrapped, err = utils.safe_wrap(name)
      if wrapped then
        reactor = wrapped
      else
        warn_once("reactor_wrap:" .. name, "Reactor wrap failed for " .. name .. ": " .. tostring(err))
      end
    else
      warn_once("reactor_missing:" .. name, "Reactor missing: " .. name)
    end
    if reactor then
      local caps = get_device_caps("reactors", name)
      if not has_reactor_rod_write_path(caps) then
        warn_unsupported(name)
        goto continue_reactor
      end
      local ok_active, active_result = pcall(setReactorActive, reactor, caps, true)
      if not ok_active then
        warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_reactor
      end
      if not active_result then
        warn_once("reactor_set_active_unavailable:" .. name, "Reactor active API unavailable for " .. name)
        goto continue_reactor
      end
      ensure_reactor_ctrl(name)
      ::continue_reactor::
    end
  end
  local target_rpm = get_target_rpm()
  for name, ctrl in pairs(turbine_ctrl) do
    local turbine
    if peripheral.isPresent(name) then
      local wrapped, err = utils.safe_wrap(name)
      if wrapped then
        turbine = wrapped
      else
        warn_once("turbine_wrap:" .. name, "Turbine wrap failed for " .. name .. ": " .. tostring(err))
      end
    else
      warn_once("turbine_missing:" .. name, "Turbine missing: " .. name)
    end
    if turbine then
      local caps = get_device_caps("turbines", name)
      local has_flow_api, flow_api_reason = turbine_has_flow_setter(turbine, caps)
      if not has_flow_api then
        ctrl.flow_api_missing_ticks = (ctrl.flow_api_missing_ticks or 0) + 1
        if ctrl.flow_api_missing_ticks >= 5 then
          warn_unsupported(name, flow_api_reason)
        else
          log("DEBUG", "TurbineCtrl startup-wait name=" .. tostring(name) .. " reason=" .. tostring(flow_api_reason) .. " missing_ticks=" .. tostring(ctrl.flow_api_missing_ticks))
        end
        goto continue_turbine
      end
      ctrl.flow_api_missing_ticks = 0
      local ok_active, active_result = pcall(setTurbineActive, turbine, caps, true)
      if not ok_active then
        warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_turbine
      end
      if not active_result then
        warn_once("turbine_set_active_unavailable:" .. name, "Turbine active API unavailable for " .. name .. " (continuing with flow control)")
      end
      local rpm = select(1, read_turbine_rpm(turbine, caps))
      local ok_inductor, inductor_result = update_inductor_for_rpm(name, turbine, caps, rpm)
      if not ok_inductor then
        warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
        goto continue_turbine
      end
      local ok, result, setter, apply_reason = apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
      if not ok then
        warn_once("turbine_flow:" .. name, "Turbine flow update failed for " .. name .. ": " .. tostring(result) .. " reason=" .. tostring(apply_reason))
        goto continue_turbine
      end
      if not result then
        log("DEBUG", "TurbineCtrl skip name=" .. name .. " reason=" .. tostring(apply_reason) .. " state=AUTONOM api=" .. tostring(setter))
      end
      ::continue_turbine::
    end
  end
end
local function updateControl()
  if current_state ~= STATE.AUTONOM and current_state ~= STATE.MASTER then
    return
  end
  for _, name in ipairs(config.reactors or {}) do
    local ok, reactor = pcall(peripheral.wrap, name)
    if ok and reactor then
      local caps = get_device_caps("reactors", name)
      if not has_reactor_rod_write_path(caps) then
        warn_unsupported(name)
        goto continue_control_reactor
      end
      local ok_active, active_result = pcall(setReactorActive, reactor, caps, true)
      if not ok_active then
        warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_control_reactor
      end
      if not active_result then
        warn_once("reactor_set_active_unavailable:" .. name, "Reactor active API unavailable for " .. name)
        goto continue_control_reactor
      end
      ensure_reactor_ctrl(name)
      if not autonom_control_logged then
        autonom_control_logged = true
        log("INFO", "AUTONOM actuator control active")
      end
      ::continue_control_reactor::
    end
  end
  local target_rpm = get_target_rpm()
  local eval_total, eval_decision, eval_skipped = 0, 0, 0
  local skip_reasons = {}
  local function track_skip(reason)
    local key = tostring(reason or "UNKNOWN")
    skip_reasons[key] = (skip_reasons[key] or 0) + 1
    eval_skipped = eval_skipped + 1
  end
  for name, ctrl in pairs(turbine_ctrl) do
    eval_total = eval_total + 1
    local ok, turbine = pcall(peripheral.wrap, name)
    if not ok or not turbine then
      track_skip("WRAP_FAILED")
      warn_once("turbine_wrap:" .. name, "Turbine wrap failed for " .. name .. ": " .. tostring(turbine))
      goto continue_control_turbine
    end
    local caps = get_device_caps("turbines", name)
    local has_flow_api, flow_api_reason = turbine_has_flow_setter(turbine, caps)
    if not has_flow_api then
      ctrl.flow_api_missing_ticks = (ctrl.flow_api_missing_ticks or 0) + 1
      track_skip(flow_api_reason)
      if ctrl.flow_api_missing_ticks >= 5 then
        warn_unsupported(name, flow_api_reason)
      else
        log("DEBUG", "TurbineCtrl startup-wait name=" .. tostring(name) .. " reason=" .. tostring(flow_api_reason) .. " missing_ticks=" .. tostring(ctrl.flow_api_missing_ticks))
      end
      goto continue_control_turbine
    end
    ctrl.flow_api_missing_ticks = 0
    local ok_active, active_result = pcall(setTurbineActive, turbine, caps, true)
    if not ok_active then
      warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(active_result))
      track_skip("SET_ACTIVE_FAILED_NONFATAL")
    elseif not active_result then
      warn_once("turbine_set_active_unavailable:" .. name, "Turbine active API unavailable for " .. name .. " (continuing with flow control)")
    end
    local rpm = nil
    if turbine.getRotorSpeed then
      local rpm_ok, value = safe_wrapped_call(turbine, "getRotorSpeed")
      if rpm_ok and type(value) == "number" then
        rpm = value
      end
    end
    local ok_inductor, inductor_result = update_inductor_for_rpm(name, turbine, caps, rpm)
    if not ok_inductor then
      warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
      track_skip("INDUCTOR_UPDATE_FAILED_NONFATAL")
    end
    local set_ok, result, _, apply_reason = apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
    if not set_ok then
      warn_once("turbine_flow:" .. name, "Turbine flow update failed for " .. name .. ": " .. tostring(result) .. " reason=" .. tostring(apply_reason))
      track_skip(apply_reason or "FLOW_SET_CALL_FAILED")
      goto continue_control_turbine
    end
    if not result then
      track_skip(apply_reason or "FLOW_SET_SKIPPED")
      log("DEBUG", "TurbineCtrl skip name=" .. name .. " reason=" .. tostring(apply_reason) .. " state=" .. tostring(current_state))
      goto continue_control_turbine
    end
    eval_decision = eval_decision + 1
    if not autonom_control_logged then
      autonom_control_logged = true
      log("INFO", "AUTONOM actuator control active")
    end
    ::continue_control_turbine::
  end
  local reason_parts = {}
  for reason, count in pairs(skip_reasons) do
    reason_parts[#reason_parts + 1] = tostring(reason) .. "=" .. tostring(count)
  end
  table.sort(reason_parts)
  log("DEBUG", "TurbineTick evaluated=" .. tostring(eval_total)
    .. " decisions=" .. tostring(eval_decision)
    .. " skipped=" .. tostring(eval_skipped)
    .. " skip_reasons=" .. (#reason_parts > 0 and table.concat(reason_parts, ",") or "none"))
end
local function adjust_turbines()
  updateControl()
end
local function adjust_reactors()
  updateReactorControl()
end
local allowed_transitions = {
  [STATE.INIT] = { [STATE.AUTONOM] = true, [STATE.MASTER] = true, [STATE.SAFE] = true },
  [STATE.MASTER] = { [STATE.AUTONOM] = true, [STATE.SAFE] = true },
  [STATE.AUTONOM] = { [STATE.MASTER] = true, [STATE.SAFE] = true },
  [STATE.SAFE] = {}
}
local function setState(new_state, transition_reason)
  if current_state == new_state then
    return false
  end
  if not allowed_transitions[current_state] or not allowed_transitions[current_state][new_state] then
    return false
  end
  local previous_state = current_state
  current_state = new_state
  if new_state == STATE.AUTONOM then
    log("INFO", "Entering AUTONOM mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
  elseif new_state == STATE.MASTER then
    if previous_state == STATE.AUTONOM then
      log("INFO", "Master reconnected reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    else
      log("INFO", "Entering MASTER mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    end
  elseif new_state == STATE.SAFE then
    log("INFO", "Entering SAFE mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    apply_safe_controls()
    set_reactors_active(false, "SAFE_MODE")
    set_turbines_active(false, "SAFE_MODE")
  else
    log("INFO", "Entering INIT mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
  end
  return true
end
local function apply_mode(mode)
  if mode == STATE.AUTONOM then
    if setState(STATE.AUTONOM, "MODE_APPLY") then
      node_state_machine:transition(constants.node_states.AUTONOM)
    end
  elseif mode == STATE.MASTER then
    if setState(STATE.MASTER, "MODE_APPLY") then
      local current = node_state_machine.state()
      if current == constants.node_states.OFF or current == constants.node_states.AUTONOM then
        node_state_machine:transition(constants.node_states.STARTUP)
      end
    end
  elseif mode == STATE.SAFE then
    setState(STATE.SAFE, "MODE_APPLY")
    if node_state_machine.state() ~= constants.node_states.EMERGENCY then
      node_state_machine:transition(constants.node_states.EMERGENCY)
    end
  end
end
local function has_off_modules(kind)
  for _, module in pairs(modules) do
    if module.type == kind and module.state == "OFF" then
      return true
    end
  end
  return false
end
local function request_startup_if_needed(reason)
  if current_state ~= STATE.MASTER then
    return false
  end
  local machine_state = node_state_machine and node_state_machine.state and node_state_machine.state() or nil
  if machine_state ~= constants.node_states.RUNNING and machine_state ~= constants.node_states.OFF then
    return false
  end
  local needs_turbine = targets.enable_turbines ~= false and has_off_modules("turbine")
  local needs_reactor = targets.enable_reactors ~= false and has_off_modules("reactor")
  if not needs_turbine and not needs_reactor then
    return false
  end
  if active_startup then
    return false
  end
  log("INFO", ("Startup requested reason=%s turbines_off=%s reactors_off=%s"):format(
    tostring(reason or "unknown"),
    tostring(needs_turbine),
    tostring(needs_reactor)
  ))
  node_state_machine:transition(constants.node_states.STARTUP)
  return true
end
cache = function()
  local function normalize_bound_names(kind, names)
    local normalized = {}
    for _, name in ipairs(names or {}) do
      local ok, methods = pcall(peripheral.getMethods, name)
      local type_name = peripheral.getType(name)
      local method_set = {}
      if ok and type(methods) == "table" then
        for _, method in ipairs(methods) do
          method_set[method] = true
        end
      end
      local detected, reason = binding.detect_kind(type_name, method_set)
      if detected == kind then
        normalized[#normalized + 1] = name
      else
        log("WARN", string.format(
          "Skipping configured %s %s: detected kind=%s type=%s reason=%s",
          tostring(kind),
          tostring(name),
          tostring(detected or "unknown"),
          tostring(type_name or "n/a"),
          tostring(reason or "n/a")
        ))
      end
    end
    return normalized
  end

  config.reactors = normalize_bound_names("reactor", config.reactors or {})
  config.turbines = normalize_bound_names("turbine", config.turbines or {})
  peripherals.reactors = utils.cache_peripherals(config.reactors) or {}
  peripherals.turbines = utils.cache_peripherals(config.turbines) or {}
  for _, name in ipairs(config.reactors) do
    capability_cache.reactors[name] = build_capabilities(name)
  end
  for _, name in ipairs(config.turbines) do
    capability_cache.turbines[name] = build_capabilities(name)
  end
end

function dumpPeripherals()
  for _, name in ipairs(peripheral.getNames()) do
    local pType = peripheral.getType(name)
    log(INFO, "Peripheral: " .. name .. " type=" .. tostring(pType))

    local methods = utils.safe_get_methods(name) or {}
    if methods then
      for _, m in ipairs(methods) do
        log(DEBUG, "  method: " .. m)
      end
    end
  end
end
local function build_binding_signature(reactors, turbines)
  local ids = {}
  for _, entry in ipairs(reactors or {}) do
    table.insert(ids, tostring(entry.id))
  end
  for _, entry in ipairs(turbines or {}) do
    table.insert(ids, tostring(entry.id))
  end
  table.sort(ids)
  return table.concat(ids, "|")
end
local function refresh_bindings()
  local reactors = registry:get_bound_devices("reactor")
  local turbines = registry:get_bound_devices("turbine")
  local signature = build_binding_signature(reactors, turbines)
  if devices.binding_signature == signature then
    return
  end
  devices.binding_signature = signature
  local reactor_names = {}
  local turbine_names = {}
  for _, entry in ipairs(reactors) do
    table.insert(reactor_names, entry.name)
  end
  for _, entry in ipairs(turbines) do
    table.insert(turbine_names, entry.name)
  end
  config.reactors = reactor_names
  config.turbines = turbine_names
  devices.reactors = reactors
  devices.turbines = turbines
  cache()
  build_modules()
  refresh_module_peripherals()
end
local function discover()
  local names = peripheral.getNames() or {}
  table.sort(names)
  local binding_policy = binding.build_policy(configured_reactors, configured_turbines)
  local adapter_map = { reactors = {}, turbines = {} }
  local registry_devices = {}
  local visible_counts = { reactor = 0, turbine = 0 }
  local bound_counts = { reactor = 0, turbine = 0 }
  local binding_decisions = {}
  local discovery_had_errors = false

  local function add_binding_decision(kind, name, type_name, bound, reason, is_error)
    table.insert(binding_decisions, {
      kind = kind,
      name = name,
      type_name = type_name,
      bound = bound and true or false,
      reason = reason,
      error = is_error and true or false
    })
    if is_error then
      discovery_had_errors = true
    end
  end

  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      table.insert(registry_devices, {
        name = name,
        type = "monitor",
        methods = utils.safe_get_methods(name) or {},
        kind = "monitor",
        bound = monitor_name == name
      })
    end
  end

  for _, name in ipairs(names) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then
      add_binding_decision("unknown", name, peripheral.getType(name), false, "methods unavailable", true)
      goto continue
    end
    local method_set = {}
    for _, method in ipairs(methods) do
      method_set[method] = true
    end
    local type_name = peripheral.getType(name)
    local kind, kind_reason = binding.detect_kind(type_name, method_set)
    if kind == "reactor" then
      visible_counts.reactor = visible_counts.reactor + 1
      local info = reactor_adapter.inspect(name, CONFIG.LOG_PREFIX)
      if info then
        local bound, reason = binding.should_bind_with_reason("reactor", name, binding_policy)
        if bound then
          adapter_map.reactors[name] = info
          bound_counts.reactor = bound_counts.reactor + 1
        end
        add_binding_decision("reactor", name, type_name, bound, reason)
        table.insert(registry_devices, {
          name = name,
          type = info.type,
          methods = info.methods,
          kind = "reactor",
          bound = bound,
          features = info.features,
          schema = info.schema
        })
      else
        add_binding_decision("reactor", name, type_name, false, "adapter inspect failed", true)
      end
    elseif kind == "turbine" then
      visible_counts.turbine = visible_counts.turbine + 1
      local info = turbine_adapter.inspect(name, CONFIG.LOG_PREFIX)
      if info then
        local bound, reason = binding.should_bind_with_reason("turbine", name, binding_policy)
        if bound then
          adapter_map.turbines[name] = info
          bound_counts.turbine = bound_counts.turbine + 1
        end
        add_binding_decision("turbine", name, type_name, bound, reason)
        table.insert(registry_devices, {
          name = name,
          type = info.type,
          methods = info.methods,
          kind = "turbine",
          bound = bound,
          features = info.features,
          schema = info.schema
        })
      else
        add_binding_decision("turbine", name, type_name, false, "adapter inspect failed", true)
      end
    else
      add_binding_decision("unknown", name, type_name, false, tostring(kind_reason), false)
    end
    ::continue::
  end

  local summary = {
    visible_reactors = visible_counts.reactor,
    visible_turbines = visible_counts.turbine,
    bound_reactors = bound_counts.reactor,
    bound_turbines = bound_counts.turbine
  }
  local discovery_signature = discovery_log.build_signature(summary, binding_decisions)
  local log_details = discovery_log.should_log_details(devices.discovery_log_signature, discovery_signature, discovery_had_errors)
  devices.discovery_log_signature = discovery_signature
  if log_details then
    for _, decision in ipairs(binding_decisions) do
      local action = decision.bound and "bound" or "rejected"
      log(INFO, string.format(
        "Discovery %s %s type=%s (%s): %s",
        tostring(decision.kind),
        tostring(decision.name),
        tostring(decision.type_name or "n/a"),
        tostring(action),
        tostring(decision.reason or "n/a")
      ))
    end
    log(INFO, string.format(
      "Discovery summary visible reactors=%d turbines=%d | bound reactors=%d turbines=%d",
      visible_counts.reactor,
      visible_counts.turbine,
      bound_counts.reactor,
      bound_counts.turbine
    ))
  else
    log(DEBUG, string.format(
      "Discovery unchanged visible reactors=%d turbines=%d | bound reactors=%d turbines=%d",
      visible_counts.reactor,
      visible_counts.turbine,
      bound_counts.reactor,
      bound_counts.turbine
    ))
  end

  registry:sync(registry_devices)
  devices.adapters = adapter_map
  devices.registry_summary = registry:get_summary()
  devices.registry_load_error = registry.state.load_error
  devices.last_scan_ts = os.epoch("utc")
  refresh_bindings()
  return registry_devices
end

build_modules = function()
  modules = {}
  for _, entry in ipairs(devices.turbines or {}) do
    local id = entry.id or ("turbine:" .. tostring(entry.name))
    modules[id] = {
      id = id,
      type = "turbine",
      state = "OFF",
      progress = 0,
      limits = {},
      name = entry.name,
      alias = entry.alias,
      stable_since = nil
    }
  end
  for _, entry in ipairs(devices.reactors or {}) do
    local id = entry.id or ("reactor:" .. tostring(entry.name))
    modules[id] = {
      id = id,
      type = "reactor",
      state = "OFF",
      progress = 0,
      limits = {},
      name = entry.name,
      alias = entry.alias,
      stable_since = nil,
      autonom_control_rod = nil
    }
  end
end

refresh_module_peripherals = function()
  local turbines = peripherals.turbines or {}
  local reactors = peripherals.reactors or {}
  for _, module in pairs(modules) do
    if module.type == "turbine" then
      module.peripheral = turbines[module.name]
      module.caps = module.peripheral and get_device_caps("turbines", module.name) or nil
    else
      module.peripheral = reactors[module.name]
      module.caps = module.peripheral and get_device_caps("reactors", module.name) or nil
    end
  end
end

function ramp_duration(profile)
  return ramp_profiles[profile] or ramp_profiles.NORMAL
end

function master_peer_state()
  local peers = comms and comms:get_peers() or {}
  for _, data in pairs(peers) do
    if data.role == constants.roles.MASTER then
      return data
    end
  end
  return nil
end

function is_master_connected()
  local peer = master_peer_state()
  if peer then
    return not peer.down, peer.age
  end
  if master_seen then
    local age = (os.epoch("utc") - master_seen) / 1000
    return age <= (hb * 5), age
  end
  return false, nil
end

function build_health_payload()
  local reasons = {}
  local summary = devices.registry_summary or registry:get_summary()
  local binding_policy = binding.build_policy(configured_reactors, configured_turbines)
  local bound_reactors = summary.kinds.reactor and summary.kinds.reactor.bound or 0
  local bound_turbines = summary.kinds.turbine and summary.kinds.turbine.bound or 0
  if bound_reactors == 0 then
    reasons[health.reasons.NO_REACTOR] = true
    warn_once("reactors_missing_health", binding.missing_devices_message("reactor", binding_policy))
  end
  if bound_turbines == 0 then
    reasons[health.reasons.NO_TURBINE] = true
    warn_once("turbines_missing_health", binding.missing_devices_message("turbine", binding_policy))
  end
  if devices.discovery_failed or devices.registry_load_error then
    reasons[health.reasons.DISCOVERY_FAILED] = true
  end
  if devices.proto_mismatch then
    reasons[health.reasons.PROTO_MISMATCH] = true
  end
  if startup_watchdog_tripped then
    reasons[health.reasons.CONTROL_DEGRADED] = true
  end
  local connected = is_master_connected()
  if not connected then
    reasons[health.reasons.COMMS_DOWN] = true
  end
  local status = next(reasons) and health.status.DEGRADED or health.status.OK
  rt_health.status = status
  rt_health.reasons = reasons
  rt_health.last_seen_ts = os.epoch("utc")
  rt_health.bindings = {
    reactors = bound_reactors,
    turbines = bound_turbines
  }
  rt_health.capabilities = { reactors = configured_caps.reactors, turbines = configured_caps.turbines }
  return {
    status = rt_health.status,
    reasons = health.reasons_list(rt_health),
    last_seen_ts = rt_health.last_seen_ts,
    bindings = rt_health.bindings,
    capabilities = rt_health.capabilities
  }
end

function add_alarm(sender, severity, message)
  comms:send_alert(severity, message)
end

function build_status_payload(status_level)
  return status_snapshot_lib.build_status_payload({
    status_level = status_level,
    node_state_machine = node_state_machine,
    current_state = current_state,
    targets = targets,
    build_health_payload = build_health_payload,
    status_snapshot = status_snapshot,
    devices = devices,
    registry = registry,
    modules = modules,
    active_startup = active_startup,
    startup_queue = startup_queue,
    turbine_adapter = turbine_adapter,
    reactor_adapter = reactor_adapter,
    log_prefix = CONFIG.LOG_PREFIX
  })
end

function broadcast_status(status_level)
  local payload = build_status_payload(status_level)
  comms:publish_status(payload)
end

function hello()
  local summary = registry:get_summary()
  local caps = {
    reactors = summary.kinds.reactor and summary.kinds.reactor.bound or 0,
    turbines = summary.kinds.turbine and summary.kinds.turbine.bound or 0
  }
  comms:send_hello(caps)
end

set_reactors_active = function(active, reason)
  local reactors = peripherals and peripherals.reactors or {}
  if not next(reactors) then
    warn_once("reactors_missing", binding.missing_devices_message("reactor", binding.build_policy(configured_reactors, configured_turbines)))
  end
  for name, reactor in pairs(reactors) do
    local caps = get_device_caps("reactors", name)
    local ok, result = pcall(setReactorActive, reactor, caps, active)
    if not ok then
      warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(result))
    elseif not result then
      warn_unsupported(name)
    else
      log("INFO", ("Reactor active name=%s active=%s reason=%s"):format(tostring(name), tostring(active), tostring(reason or "UNSPECIFIED")))
    end
  end
end

set_turbines_active = function(active, reason)
  local turbines = peripherals and peripherals.turbines or {}
  if not next(turbines) then
    warn_once("turbines_missing", binding.missing_devices_message("turbine", binding.build_policy(configured_reactors, configured_turbines)))
  end
  for name, turbine in pairs(turbines) do
    local caps = get_device_caps("turbines", name)
    local ok, result = pcall(setTurbineActive, turbine, caps, active)
    if not ok then
      warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(result))
    else
      local ctrl = get_turbine_ctrl(name)
      if ctrl.last_active_command ~= active or ctrl.last_active_command_reason ~= reason then
        ctrl.last_active_command = active
        ctrl.last_active_command_reason = reason
        log("INFO", ("Turbine active name=%s active=%s reason=%s"):format(
          tostring(name),
          tostring(active),
          tostring(reason or "UNSPECIFIED")
        ))
      end
    end
  end
end

apply_safe_controls = function()
  local reactors = peripherals and peripherals.reactors or {}
  if not next(reactors) then
    warn_once("reactors_missing", binding.missing_devices_message("reactor", binding.build_policy(configured_reactors, configured_turbines)))
  end
  for name, reactor in pairs(reactors) do
    local caps = get_device_caps("reactors", name)
    if has_reactor_rod_write_path(caps) then
      local ctrl = ensure_reactor_ctrl(name)
      ctrl.last_applied = nil
    else
      warn_unsupported(name)
    end
  end
  applyReactorRods(100, true)

  local turbines = peripherals and peripherals.turbines or {}
  if not next(turbines) then
    warn_once("turbines_missing", binding.missing_devices_message("turbine", binding.build_policy(configured_reactors, configured_turbines)))
  end
  for name, turbine in pairs(turbines) do
    local caps = get_device_caps("turbines", name)
    local _, rpm_value = safe_wrapped_call(turbine, "getRotorSpeed")
    local rpm = type(rpm_value) == "number" and rpm_value or nil
    if caps.setInductorEngaged then
      local ok, result = update_inductor_for_rpm(name, turbine, caps, rpm)
      if not ok then
        warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(result))
      elseif not result then
        warn_unsupported(name)
      end
    end
    if caps.setFluidFlowRate or caps.setFluidFlowRateMax then
      local ctrl = get_turbine_ctrl(name)
      ctrl.mode = TURBINE_MODE.RAMP
      ctrl.requested_flow = clamp_turbine_flow(ctrl.requested_flow or ctrl.flow or START_FLOW)
      ctrl.flow = ctrl.requested_flow
      ctrl.pending_expected_flow = ctrl.requested_flow
      ctrl.pending_flow_since = 0
      ctrl.pending_retries = 0
      ctrl.startup_synced = false
      local ok, result = pcall(setTurbineFlow, turbine, caps, ctrl.requested_flow)
      if not ok then
        warn_once("turbine_flow:" .. name, "Turbine flow update failed for " .. name .. ": " .. tostring(result))
      elseif not result then
        warn_unsupported(name)
      end
    else
      warn_unsupported(name)
    end
  end
end

function scram()
  log("ERROR", "SCRAM ownership=STATE_MACHINE action=SCRAM_APPLY current_state=" .. tostring(current_state))
  apply_safe_controls()
  if current_state == STATE.SAFE then
    set_reactors_active(false, "SCRAM_SAFE_STATE")
    set_turbines_active(false, "SCRAM_SAFE_STATE")
  end
end

function build_module_lifecycle_context()
  return {
    constants = constants,
    STATE = STATE,
    config = config,
    modules = modules,
    comms = comms,
    RPM_TOL = RPM_TOL,
    TURBINE_MODE = TURBINE_MODE,
    log = log,
    warn_once = warn_once,
    warn_unsupported = warn_unsupported,
    get_target_rpm = get_target_rpm,
    get_turbine_ctrl = get_turbine_ctrl,
    ensure_reactor_ctrl = ensure_reactor_ctrl,
    setTurbineActive = setTurbineActive,
    setReactorActive = setReactorActive,
    setTurbineFlow = setTurbineFlow,
    update_inductor_for_rpm = update_inductor_for_rpm,
    update_turbine_flow_state = update_turbine_flow_state,
    applyReactorRods = applyReactorRods,
    add_alarm = add_alarm,
    ramp_duration = ramp_duration,
    evaluate_reactor_coolant = evaluate_reactor_coolant,
    get_active_startup = function() return active_startup end,
    set_active_startup = function(value) active_startup = value end,
    current_state = function() return current_state end,
    setState = setState,
    node_state_machine = node_state_machine
  }
end

function update_module_limits(module)
  return module_lifecycle.update_module_limits(build_module_lifecycle_context(), module)
end

function start_module(module_id, module_type, ramp_profile)
  return module_lifecycle.start_module(build_module_lifecycle_context(), module_id, module_type, ramp_profile)
end

function process_startup()
  module_lifecycle.process_startup(build_module_lifecycle_context())
end

function update_module_states()
  module_lifecycle.update_module_states(build_module_lifecycle_context())
end

function monitor_master()
  local connected = is_master_connected()
  if not connected then
    if setState(STATE.AUTONOM, "MASTER_TIMEOUT_AUTONOM_FALLBACK") then
      log("WARN", "Master timeout detected, switching to AUTONOM")
      node_state_machine:transition(constants.node_states.AUTONOM)
    end
  end
end

function clamp_autonom_targets()
  targets.power = 0
  targets.rpm = ramp_towards(targets.rpm, TARGET_RPM, config.autonom.flow_step)
  targets.steam = 0
end

function note_master_seen()
  master_seen = os.epoch("utc")
end

function update_status_snapshot()
  last_status_snapshot = status_snapshot_lib.update_status_snapshot({
    monitor_ui = monitor_ui,
    devices = devices,
    registry = registry,
    comms = comms,
    config = config,
    read_turbine_rpm = read_turbine_rpm,
    read_turbine_flow = read_turbine_flow,
    reactor_adapter = reactor_adapter,
    turbine_adapter = turbine_adapter,
    log_prefix = "RT",
    get_device_caps = get_device_caps,
    get_available_steam = get_available_steam,
    last_status_snapshot = last_status_snapshot
  })
  return last_status_snapshot
end

function init_monitor()
  local monitor_name_or_err
  monitor, monitor_name_or_err = monitor_ui.init(monitor_adapter, config.monitor, config.monitor_scale)
  if not monitor then
    log(WARN, "Monitor UI disabled: " .. tostring(monitor_name_or_err or "no monitor available"))
  elseif monitor_name_or_err then
    log(INFO, "Monitor UI initialized on " .. tostring(monitor_name_or_err))
  end
end

function update_monitor()
  last_status_snapshot = monitor_ui.update(monitor, {
    config = config,
    devices = devices,
    registry = registry,
    comms = comms,
    constants = constants,
    master_alerts = master_alerts,
    last_command = last_command,
    last_command_ts = last_command_ts,
    current_state = current_state,
    configured_reactors = configured_reactors,
    configured_turbines = configured_turbines,
    get_target_rpm = get_target_rpm,
    binding = binding,
    build_health_payload = build_health_payload,
    read_turbine_rpm = read_turbine_rpm,
    read_turbine_flow = read_turbine_flow,
    reactor_adapter = reactor_adapter,
    turbine_adapter = turbine_adapter,
    log_prefix = "RT",
    get_device_caps = get_device_caps,
    get_available_steam = get_available_steam,
    last_status_snapshot = last_status_snapshot
  })
end

function reset_startup_watchdog()
  startup_started_ms = nil
  startup_watchdog_tripped = false
end

function build_peripheral_summary()
  local summary = devices.registry_summary or registry:get_summary() or {}
  return startup_diagnostics.build_peripheral_summary(summary)
end

function should_emergency_startup(snapshot)
  return startup_diagnostics.should_emergency_startup(snapshot, config.safety.max_temperature, config.safety.max_rpm)
end

function handle_startup_timeout()
  if startup_watchdog_tripped then
    return
  end
  startup_watchdog_tripped = true
  local now = os.epoch("utc")
  local elapsed_s = startup_started_ms and (now - startup_started_ms) / 1000 or 0
  local node_id = comms and comms.network and comms.network.id or config.node_id
  local summary = build_peripheral_summary()
  log("ERROR", ("Startup watchdog tripped role=%s node=%s elapsed=%.1fs %s"):format(
    tostring(config.role or "RT"),
    tostring(node_id),
    elapsed_s,
    summary
  ))

  local snapshot = update_status_snapshot()
  local emergency = should_emergency_startup(snapshot)
  local status_level = emergency and constants.status_levels.EMERGENCY or constants.status_levels.WARNING
  broadcast_status(status_level)
  if emergency then
    if node_state_machine.state() ~= constants.node_states.EMERGENCY then
      node_state_machine:transition(constants.node_states.EMERGENCY)
    end
  else
    if node_state_machine.state() ~= constants.node_states.LIMITED then
      node_state_machine:transition(constants.node_states.LIMITED)
    end
  end
  active_startup = nil
  startup_queue = {}
end
local states

function build_state_context()
  return {
    constants = constants,
    STATE = STATE,
    config = config,
    devices = devices,
    modules = modules,
    comms = comms,
    targets = targets,
    reset_startup_watchdog = reset_startup_watchdog,
    scram = scram,
    monitor_master = monitor_master,
    get_target_rpm = get_target_rpm,
    start_module = start_module,
    adjust_turbines = adjust_turbines,
    adjust_reactors = adjust_reactors,
    clamp_autonom_targets = clamp_autonom_targets,
    add_alarm = add_alarm,
    handle_startup_timeout = handle_startup_timeout,
    get_startup_started_ms = function() return startup_started_ms end,
    set_startup_started_ms = function(value) startup_started_ms = value end,
    get_startup_watchdog_tripped = function() return startup_watchdog_tripped end,
    set_startup_watchdog_tripped = function(value) startup_watchdog_tripped = value end,
    get_startup_queue = function() return startup_queue end,
    set_startup_queue = function(value) startup_queue = value end,
    get_active_startup = function() return active_startup end,
    set_active_startup = function(value) active_startup = value end,
    get_network_id = function() return (comms and comms.network and comms.network.id) or config.node_id end,
    get_current_state = function() return current_state end,
    get_node_state_machine = function() return node_state_machine end
  }
end

function build_command_context()
  return {
    protocol = protocol,
    constants = constants,
    STATE = STATE,
    TARGET_RPM = TARGET_RPM,
    targets = targets,
    node_state_machine = node_state_machine,
    apply_mode = apply_mode,
    request_startup_if_needed = request_startup_if_needed,
    start_module = start_module,
    add_alarm = add_alarm,
    note_master_seen = note_master_seen,
    get_network_id = function() return (comms and comms.network and comms.network.id) or config.node_id end,
    get_current_state = function() return current_state end,
    get_states = function() return states or {} end,
    set_last_command = function(value) last_command = value end,
    set_last_command_ts = function(value) last_command_ts = value end
  }
end
local handle_command

function send_heartbeat()
  update_status_snapshot()
  comms:send_heartbeat({ state = node_state_machine.state() })
  broadcast_status(constants.status_levels.OK)
  last_heartbeat = os.epoch("utc")
end

function control_tick()
  refresh_module_peripherals()
  process_startup()
  update_module_states()
  updateReactorControl()
  request_startup_if_needed("CONTROL_TICK")
  if current_state == STATE.SAFE and node_state_machine.state() ~= constants.node_states.EMERGENCY then
    node_state_machine:transition(constants.node_states.EMERGENCY)
  end
  node_state_machine:tick()
  update_monitor()
  update_status_snapshot()
end
local function init()
  dumpPeripherals()
  discover()
  init_turbine_ctrl()
  init_reactor_ctrl()
  set_reactors_active(true, "RT_STARTUP")
  set_turbines_active(true, "RT_STARTUP")
  apply_initial_reactor_rods()
  services = service_manager.new({ log_prefix = "RT" })
  handle_command = command_handler.new(build_command_context())
  comms = comms_service.new({
    config = config,
    log_prefix = "RT",
    on_command = handle_command,
    on_message = function(message)
      if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then
        devices.proto_mismatch = true
        return
      end
      if message.role == constants.roles.MASTER then
        note_master_seen()
        if message.type == constants.message_types.STATUS and message.payload and message.payload.alerts then
          master_alerts = message.payload.alerts
        end
      end
    end
  })
  services:add(comms)
  services:add(discovery_service.new({
    registry = registry,
    discover = discover,
    interval = config.scan_interval,
    managed_registry = false,
    update_health = function(ok)
      devices.discovery_failed = not ok
    end
  }))
  services:add(control_service.new({ tick = control_tick }))
  services:add(telemetry_service.new({
    comms = comms,
    status_interval = config.status_interval or config.heartbeat_interval,
    heartbeat_interval = config.heartbeat_interval,
    heartbeat_state = function() return { state = node_state_machine.state() } end,
    build_payload = function()
      update_status_snapshot()
      return build_status_payload(constants.status_levels.OK)
    end
  }))
  services:init()
  states = state_handlers.build(build_state_context())
  node_state_machine = machine.new(states, constants.node_states.OFF)
  apply_mode(STATE.AUTONOM)
  init_monitor()
  hello()
  send_heartbeat()
  log("INFO", "Node ready: " .. comms.network.id)
end

init()
while true do
  local timer = os.startTimer(CONFIG.RECEIVE_TIMEOUT)
  while true do
    local event = { os.pullEvent() }
    if event[1] == "modem_message" then
      comms:handle_event(event)
    elseif event[1] == "timer" and event[2] == timer then
      break
    elseif event[1] == "monitor_touch" or event[1] == "key" then
      monitor_ui.handle_input(event)
    end
  end
  if os.epoch("utc") - last_heartbeat > hb * 1000 then
    send_heartbeat()
  end
  services:tick()
end
