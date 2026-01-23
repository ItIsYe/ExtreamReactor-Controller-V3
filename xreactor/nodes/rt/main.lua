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
  MIN_FLOW = 200, -- Minimum turbine flow.
  MAX_FLOW = 1900, -- Maximum turbine flow.
  FLOW_STEP = 50, -- Flow adjustment step size.
  COIL_ENGAGE_RPM = 850, -- RPM at which coils engage.
  COIL_DISENGAGE_RPM = 750, -- RPM at which coils disengage.
  START_FLOW = 200, -- Starting flow value when enabling turbines.
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
_G.turbine_ctrl = type(_G.turbine_ctrl) == "table" and _G.turbine_ctrl or {}

local function ensure_turbine_ctrl(name)
  _G.turbine_ctrl = type(_G.turbine_ctrl) == "table" and _G.turbine_ctrl or {}
  _G.ensure_turbine_ctrl = ensure_turbine_ctrl
  if not name then
    name = "__unknown__"
  end
  local ctrl = _G.turbine_ctrl[name]
  if type(ctrl) ~= "table" then
    ctrl = {}
    _G.turbine_ctrl[name] = ctrl
  end
  if ctrl.mode == nil then
    ctrl.mode = "INIT"
  end
  if ctrl.flow == nil then
    ctrl.flow = 0
  end
  if ctrl.target_flow == nil then
    ctrl.target_flow = 0
  end
  if ctrl.last_rpm == nil then
    ctrl.last_rpm = 0
  end
  if ctrl.last_update == nil then
    ctrl.last_update = os.clock()
  end
  return ctrl
end

local get_turbine_ctrl = ensure_turbine_ctrl
local constants = require("shared.constants")
local colors = require("shared.colors")
local protocol = require("core.protocol")
local utils = require("core.utils")
local safety = require("core.safety")
local health = require("core.health")
local machine = require("core.state_machine")
local registry_lib = require("core.registry")
local reactor_adapter = require("adapters.reactor")
local turbine_adapter = require("adapters.turbine")
local monitor_adapter = require("adapters.monitor")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local discovery_service = require("services.discovery_service")
local telemetry_service = require("services.telemetry_service")
local control_service = require("services.control_service")

local INFO = "INFO"
local DEBUG = "DEBUG"
local WARN = "WARN"

local function log(level, message)
  utils.log(CONFIG.LOG_PREFIX, message, level)
end

local DEFAULT_CONFIG = {
  role = constants.roles.RT_NODE, -- Node role identifier.
  node_id = "RT-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor/logs/rt.log.
  wireless_modem = "right", -- Default wireless modem side.
  wired_modem = nil, -- Optional wired modem side.
  modem = "right", -- Default modem side or peripheral name.
  reactors = { "BigReactors-Reactor_6" }, -- Default reactor peripheral names.
  turbines = { "BigReactors-Turbine_327", "BigReactors-Turbine_426" }, -- Default turbine peripheral names.
  heartbeat_interval = 2, -- Seconds between status heartbeats.
  scan_interval = 10, -- Seconds between peripheral discovery scans.
  channels = {
    control = constants.channels.CONTROL, -- Control channel for MASTER commands.
    status = constants.channels.STATUS -- Status channel for telemetry.
  },
  safety = {
    max_temperature = 2000, -- Maximum reactor temperature before SCRAM.
    max_rpm = 1800, -- Maximum turbine RPM.
    min_water = 0.2 -- Minimum water ratio before SCRAM.
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
    reactor_adjust_interval = CONFIG.ROD_TICK, -- Reactor adjust interval.
    steam_reserve = 5000, -- Steam reserve threshold.
    steam_deficit = 5000 -- Steam deficit threshold.
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

local function validate_config(config_values, defaults)
  local normalized = utils.normalize_node_id(config_values.node_id)
  if normalized == "UNKNOWN" then
    config_values.node_id = defaults.node_id
    add_config_warning("node_id missing/invalid; defaulting to " .. tostring(defaults.node_id))
  else
    config_values.node_id = normalized
  end
  if type(config_values.role) ~= "string" then
    config_values.role = defaults.role
    add_config_warning("role missing/invalid; defaulting to " .. tostring(defaults.role))
  end
  if type(config_values.debug_logging) ~= "boolean" then
    config_values.debug_logging = defaults.debug_logging
    add_config_warning("debug_logging missing/invalid; defaulting to " .. tostring(defaults.debug_logging))
  end
  if type(config_values.wireless_modem) ~= "string" then
    config_values.wireless_modem = defaults.wireless_modem
    add_config_warning("wireless_modem missing/invalid; defaulting to " .. tostring(defaults.wireless_modem))
  end
  if config_values.wired_modem ~= nil and type(config_values.wired_modem) ~= "string" then
    config_values.wired_modem = defaults.wired_modem
    add_config_warning("wired_modem invalid; defaulting to " .. tostring(defaults.wired_modem))
  end
  if config_values.modem ~= nil and type(config_values.modem) ~= "string" then
    config_values.modem = defaults.modem
    add_config_warning("modem invalid; defaulting to " .. tostring(defaults.modem))
  end
  if type(config_values.reactors) ~= "table" then
    config_values.reactors = utils.deep_copy(defaults.reactors)
    add_config_warning("reactors missing/invalid; defaulting to configured list")
  end
  if type(config_values.turbines) ~= "table" then
    config_values.turbines = utils.deep_copy(defaults.turbines)
    add_config_warning("turbines missing/invalid; defaulting to configured list")
  end
  if type(config_values.heartbeat_interval) ~= "number" or config_values.heartbeat_interval <= 0 then
    config_values.heartbeat_interval = defaults.heartbeat_interval
    add_config_warning("heartbeat_interval missing/invalid; defaulting to " .. tostring(defaults.heartbeat_interval))
  end
  if type(config_values.scan_interval) ~= "number" or config_values.scan_interval <= 0 then
    config_values.scan_interval = defaults.scan_interval
    add_config_warning("scan_interval missing/invalid; defaulting to " .. tostring(defaults.scan_interval))
  end
  if type(config_values.channels) ~= "table" then
    config_values.channels = utils.deep_copy(defaults.channels)
    add_config_warning("channels missing/invalid; defaulting to control/status defaults")
  end
  if type(config_values.channels.control) ~= "number" then
    config_values.channels.control = defaults.channels.control
    add_config_warning("channels.control missing/invalid; defaulting to " .. tostring(defaults.channels.control))
  end
  if type(config_values.channels.status) ~= "number" then
    config_values.channels.status = defaults.channels.status
    add_config_warning("channels.status missing/invalid; defaulting to " .. tostring(defaults.channels.status))
  end
  if type(config_values.safety) ~= "table" then
    config_values.safety = utils.deep_copy(defaults.safety)
    add_config_warning("safety missing/invalid; defaulting to safety defaults")
  end
  if type(config_values.safety.max_temperature) ~= "number" then
    config_values.safety.max_temperature = defaults.safety.max_temperature
    add_config_warning("safety.max_temperature missing/invalid; defaulting to " .. tostring(defaults.safety.max_temperature))
  end
  if type(config_values.safety.max_rpm) ~= "number" then
    config_values.safety.max_rpm = defaults.safety.max_rpm
    add_config_warning("safety.max_rpm missing/invalid; defaulting to " .. tostring(defaults.safety.max_rpm))
  end
  if type(config_values.safety.min_water) ~= "number" then
    config_values.safety.min_water = defaults.safety.min_water
    add_config_warning("safety.min_water missing/invalid; defaulting to " .. tostring(defaults.safety.min_water))
  end
  if type(config_values.autonom) ~= "table" then
    config_values.autonom = utils.deep_copy(defaults.autonom)
    add_config_warning("autonom missing/invalid; defaulting to autonom defaults")
  end
  if type(config_values.autonom.control_rod_level) ~= "number" then
    config_values.autonom.control_rod_level = defaults.autonom.control_rod_level
    add_config_warning("autonom.control_rod_level missing/invalid; defaulting to " .. tostring(defaults.autonom.control_rod_level))
  end
  if type(config_values.autonom.max_rpm) ~= "number" then
    config_values.autonom.max_rpm = defaults.autonom.max_rpm
    add_config_warning("autonom.max_rpm missing/invalid; defaulting to " .. tostring(defaults.autonom.max_rpm))
  end
  if type(config_values.autonom.min_flow) ~= "number" then
    config_values.autonom.min_flow = defaults.autonom.min_flow
    add_config_warning("autonom.min_flow missing/invalid; defaulting to " .. tostring(defaults.autonom.min_flow))
  end
  if type(config_values.autonom.max_flow) ~= "number" then
    config_values.autonom.max_flow = defaults.autonom.max_flow
    add_config_warning("autonom.max_flow missing/invalid; defaulting to " .. tostring(defaults.autonom.max_flow))
  end
  if type(config_values.autonom.flow_step) ~= "number" then
    config_values.autonom.flow_step = defaults.autonom.flow_step
    add_config_warning("autonom.flow_step missing/invalid; defaulting to " .. tostring(defaults.autonom.flow_step))
  end
  if type(config_values.autonom.ramp_step) ~= "number" then
    config_values.autonom.ramp_step = defaults.autonom.ramp_step
    add_config_warning("autonom.ramp_step missing/invalid; defaulting to " .. tostring(defaults.autonom.ramp_step))
  end
  if type(config_values.autonom.min_rods) ~= "number" then
    config_values.autonom.min_rods = defaults.autonom.min_rods
    add_config_warning("autonom.min_rods missing/invalid; defaulting to " .. tostring(defaults.autonom.min_rods))
  end
  if type(config_values.autonom.max_rods) ~= "number" then
    config_values.autonom.max_rods = defaults.autonom.max_rods
    add_config_warning("autonom.max_rods missing/invalid; defaulting to " .. tostring(defaults.autonom.max_rods))
  end
  if type(config_values.autonom.reactor_adjust_interval) ~= "number" then
    config_values.autonom.reactor_adjust_interval = defaults.autonom.reactor_adjust_interval
    add_config_warning("autonom.reactor_adjust_interval missing/invalid; defaulting to " .. tostring(defaults.autonom.reactor_adjust_interval))
  end
  if type(config_values.autonom.steam_reserve) ~= "number" then
    config_values.autonom.steam_reserve = defaults.autonom.steam_reserve
    add_config_warning("autonom.steam_reserve missing/invalid; defaulting to " .. tostring(defaults.autonom.steam_reserve))
  end
  if type(config_values.autonom.steam_deficit) ~= "number" then
    config_values.autonom.steam_deficit = defaults.autonom.steam_deficit
    add_config_warning("autonom.steam_deficit missing/invalid; defaulting to " .. tostring(defaults.autonom.steam_deficit))
  end
  if type(config_values.monitor_interval) ~= "number" or config_values.monitor_interval <= 0 then
    config_values.monitor_interval = defaults.monitor_interval
    add_config_warning("monitor_interval missing/invalid; defaulting to " .. tostring(defaults.monitor_interval))
  end
  if type(config_values.monitor_scale) ~= "number" or config_values.monitor_scale <= 0 then
    config_values.monitor_scale = defaults.monitor_scale
    add_config_warning("monitor_scale missing/invalid; defaulting to " .. tostring(defaults.monitor_scale))
  end
  if type(config_values.status_interval) ~= "number" or config_values.status_interval <= 0 then
    config_values.status_interval = defaults.status_interval
    add_config_warning("status_interval missing/invalid; defaulting to " .. tostring(defaults.status_interval))
  end
  if config_values.status_log ~= nil and type(config_values.status_log) ~= "boolean" then
    config_values.status_log = defaults.status_log
    add_config_warning("status_log invalid; defaulting to " .. tostring(defaults.status_log))
  end
end

validate_config(config, DEFAULT_CONFIG)
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
utils.init_logger({ log_name = log_name, prefix = CONFIG.LOG_PREFIX, enabled = debug_enabled })
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
config.safety = config.safety or {}
config.safety.max_temperature = config.safety.max_temperature or DEFAULT_CONFIG.safety.max_temperature
config.safety.max_rpm = config.safety.max_rpm or DEFAULT_CONFIG.safety.max_rpm
config.safety.min_water = config.safety.min_water or DEFAULT_CONFIG.safety.min_water
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
config.autonom.reactor_adjust_interval = config.autonom.reactor_adjust_interval or ROD_TICK
config.autonom.steam_reserve = config.autonom.steam_reserve or DEFAULT_CONFIG.autonom.steam_reserve
config.autonom.steam_deficit = config.autonom.steam_deficit or DEFAULT_CONFIG.autonom.steam_deficit
config.monitor_interval = config.monitor_interval or DEFAULT_CONFIG.monitor_interval
config.monitor_scale = config.monitor_scale or DEFAULT_CONFIG.monitor_scale
config.scan_interval = config.scan_interval or DEFAULT_CONFIG.scan_interval
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
  last_scan_ts = nil
}
local peripherals = {}
local targets = { power = 0, steam = 0, rpm = TARGET_RPM, enable_reactors = true, enable_turbines = true }
local modules = {}
local active_startup = nil
local startup_queue = {}
local master_seen = os.epoch("utc")
local last_heartbeat = 0
local last_reactor_tick = 0
local last_reactor_debug_log = 0
local status_snapshot = nil
local last_snapshot = 0
local monitor = nil
local monitor_name = nil
local last_monitor_update = 0
local last_monitor_page = 0
local monitor_page = 1
local last_actuator_update = 0
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
  if type(rate) ~= "number" then
    rate = config.autonom.min_flow
  end
  return safety.clamp(rate, MIN_FLOW, MAX_FLOW)
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
      local tank = peripheral.wrap(name)
      if tank and tank.getFluidAmount then
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
  local tank = peripheral.wrap(name)
  if tank and tank.getFluidAmount then
    local ok, amount = pcall(tank.getFluidAmount)
    if ok and type(amount) == "number" then
      return amount
    end
  end
  return nil
end

local function read_reactor_steam_amount()
  local total = 0
  local found = false
  for _, name in ipairs(config.reactors or {}) do
    local reactor = peripherals.reactors[name] or peripheral.wrap(name)
    if reactor then
      local amount = nil
      if reactor.getHotFluidAmount then
        local ok, value = pcall(reactor.getHotFluidAmount)
        if ok and type(value) == "number" then
          amount = value
        end
      elseif reactor.getSteamAmount then
        local ok, value = pcall(reactor.getSteamAmount)
        if ok and type(value) == "number" then
          amount = value
        end
      elseif reactor.getSteam then
        local ok, value = pcall(reactor.getSteam)
        if ok and type(value) == "number" then
          amount = value
        end
      end
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
      local turbine = peripherals.turbines[name] or peripheral.wrap(name)
      if turbine and turbine.getRotorSpeed then
        local ok, value = pcall(turbine.getRotorSpeed)
        if ok and type(value) == "number" then
          rpm = value
        end
      end
    end
    if type(rpm) == "number" and rpm > MIN_ACTIVE_RPM then
      total = total + (ctrl.flow or 0)
    end
  end
  return total
end

local function reactor_low_water(reactor)
  if not reactor or not reactor.getCoolantAmount or not reactor.getCoolantAmountMax then
    return false
  end
  local ok_amount, amount = pcall(reactor.getCoolantAmount)
  local ok_max, max = pcall(reactor.getCoolantAmountMax)
  if not ok_amount or not ok_max or type(amount) ~= "number" or type(max) ~= "number" or max <= 0 then
    return false
  end
  return (amount / max) <= config.safety.min_water
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

local function build_capabilities(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    methods = {}
  end
  return {
    setActive = has_method(methods, "setActive"),
    setFluidFlowRate = has_method(methods, "setFluidFlowRate"),
    setFluidFlowRateMax = has_method(methods, "setFluidFlowRateMax"),
    getControlRods = has_method(methods, "getControlRods"),
    setInductorEngaged = has_method(methods, "setInductorEngaged"),
    setAllControlRodLevels = has_method(methods, "setAllControlRodLevels")
  }
end

local function init_turbine_ctrl()
  for key in pairs(turbine_ctrl) do
    turbine_ctrl[key] = nil
  end
  autonom_state.turbines = turbine_ctrl
  local turbines = config.turbines or {}
  log("INFO", "Detected " .. tostring(#turbines) .. " turbines")
  if #turbines < 1 then
    log("ERROR", "No turbines detected")
    return
  end
  for _, name in ipairs(turbines) do
    local ctrl = get_turbine_ctrl(name)
    ctrl.flow = clamp_turbine_flow(START_FLOW)
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
  if caps.setFluidFlowRate then
    turbine.setFluidFlowRate(clamped)
    return true
  elseif caps.setFluidFlowRateMax then
    turbine.setFluidFlowRateMax(clamped)
    return true
  end
  return false
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
  return false
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
  for name, ctrl in pairs(reactor_ctrl) do
    local reactor = peripheral.wrap(name)
    local caps = get_device_caps("reactors", name)
    if reactor and caps.setAllControlRodLevels then
      local ok, result = pcall(reactor.setAllControlRodLevels, clamped)
      if ok and result ~= false then
        ctrl.last_applied = clamped
      else
        warn_once("reactor_rods:" .. name, "Reactor control rod write failed for " .. name)
      end
    elseif reactor and reactor.getControlRods then
      local ok_rods, rods = pcall(reactor.getControlRods)
      if ok_rods and type(rods) == "table" then
        for _, rod in pairs(rods) do
          if rod and rod.setLevel then
            pcall(rod.setLevel, clamped)
          end
        end
        ctrl.last_applied = clamped
      else
        warn_once("reactor_rods:" .. name, "Reactor control rod read failed for " .. name)
      end
    else
      warn_once("reactor_rods:" .. name, "Reactor control rods unsupported for " .. name)
    end
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
    local reactor = peripheral.wrap(name)
    if reactor and reactor.getControlRodLevel then
      local ok_rods, current_rods = pcall(reactor.getControlRodLevel, 0)
      if ok_rods and type(current_rods) == "number" then
        return current_rods
      end
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
  local sample_rods = read_current_rods() or ROD_MAX
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

  local target_rods = current_rods
  if steam_margin > config.autonom.steam_reserve then
    target_rods = current_rods + REACTOR_STEP
  elseif steam_margin < -config.autonom.steam_deficit then
    target_rods = current_rods - REACTOR_STEP
  end

  target_rods = safety.clamp(target_rods, ROD_MIN, ROD_MAX)
  if target_rods == current_rods then
    return
  end

  local applied = applyReactorRods(target_rods, false)
  if applied then
    log("INFO", string.format("ReactorCtrl margin=%.1f rods=%d", steam_margin, target_rods))
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

local function warn_unsupported(name)
  warn_once("device_unsupported:" .. name, "Device unsupported by API: " .. name)
end

local function update_inductor_for_rpm(name, turbine, caps, rpm)
  local ctrl = get_turbine_ctrl(name)
  local engaged = ctrl.inductor_engaged or false
  if rpm and rpm >= COIL_ENGAGE_RPM and not engaged then
    engaged = true
  elseif (not rpm or rpm <= COIL_DISENG_RPM) and engaged then
    engaged = false
  end
  if engaged == ctrl.inductor_engaged then
    return true, true
  end
  ctrl.inductor_engaged = engaged
  return pcall(setInductor, turbine, caps, engaged)
end

local function update_turbine_flow_state(rpm, target_rpm, ctrl)
  local mode = ctrl.mode or TURBINE_MODE.RAMP
  local ramp_step = FLOW_STEP
  local flow_step = FLOW_STEP
  local target = target_rpm or TARGET_RPM
  if mode == TURBINE_MODE.RAMP then
    if not rpm or rpm < target then
      ctrl.flow = ctrl.flow + ramp_step
    else
      ctrl.mode = TURBINE_MODE.REGULATE
      if rpm and rpm > target + RPM_TOL then
        ctrl.flow = ctrl.flow - flow_step
      end
    end
  else
    if rpm and rpm < target - RPM_TOL then
      ctrl.flow = ctrl.flow + flow_step
    elseif rpm and rpm > target + RPM_TOL then
      ctrl.flow = ctrl.flow - flow_step
    end
  end
  ctrl.flow = clamp_turbine_flow(ctrl.flow)
  return ctrl.flow, ctrl.mode
end

local function apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
  local ctrl = get_turbine_ctrl(name)
  if type(rpm) == "number" then
    ctrl.rpm = rpm
  end
  local flow, mode = update_turbine_flow_state(rpm, target_rpm, ctrl)
  local ok, result = pcall(setTurbineFlow, turbine, caps, flow)
  log("DEBUG", "Turbine " .. name .. " rpm=" .. tostring(rpm) .. " flow=" .. tostring(flow) .. " mode=" .. tostring(mode) .. " coil=" .. tostring(ctrl.inductor_engaged))
  if not ctrl.logged then
    log("INFO", "Turbine " .. name .. " active, initial flow " .. tostring(ctrl.flow))
    ctrl.logged = true
  end
  return ok, result
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
      if not (caps.getControlRods or caps.setAllControlRodLevels) then
        warn_unsupported(name)
        goto continue_reactor
      end
      local ok_active, active_result = pcall(setReactorActive, reactor, caps, true)
      if not ok_active then
        warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_reactor
      end
      if not active_result then
        warn_unsupported(name)
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
      if not caps.setInductorEngaged then
        warn_unsupported(name)
        goto continue_turbine
      end
      if not (caps.setFluidFlowRate or caps.setFluidFlowRateMax) then
        warn_unsupported(name)
        goto continue_turbine
      end
      local ok_active, active_result = pcall(setTurbineActive, turbine, caps, true)
      if not ok_active then
        warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_turbine
      end
      if not active_result then
        warn_unsupported(name)
        goto continue_turbine
      end
      local rpm = nil
      if turbine.getRotorSpeed then
        local ok, value = pcall(turbine.getRotorSpeed)
        if ok and type(value) == "number" then
          rpm = value
        end
      end
      local ok_inductor, inductor_result = update_inductor_for_rpm(name, turbine, caps, rpm)
      if not ok_inductor then
        warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
        goto continue_turbine
      end
      if not inductor_result then
        warn_unsupported(name)
        goto continue_turbine
      end
      local ok, result = apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
      if not ok then
        warn_once("turbine_flow:" .. name, "Turbine flow update failed for " .. name .. ": " .. tostring(result))
        goto continue_turbine
      end
      if not result then
        warn_unsupported(name)
      end
      ::continue_turbine::
    end
  end
end

local function updateControl()
  if current_state ~= STATE.AUTONOM then
    return
  end
  for _, name in ipairs(config.reactors or {}) do
    local ok, reactor = pcall(peripheral.wrap, name)
    if ok and reactor then
      local caps = get_device_caps("reactors", name)
      if not (caps.getControlRods or caps.setAllControlRodLevels) then
        warn_unsupported(name)
        goto continue_control_reactor
      end
      local ok_active, active_result = pcall(setReactorActive, reactor, caps, true)
      if not ok_active then
        warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_control_reactor
      end
      if not active_result then
        warn_unsupported(name)
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
  for name, ctrl in pairs(turbine_ctrl) do
    local ok, turbine = pcall(peripheral.wrap, name)
    if ok and turbine then
      local caps = get_device_caps("turbines", name)
      if not caps.setInductorEngaged then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      if not (caps.setFluidFlowRate or caps.setFluidFlowRateMax) then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      local ok_active, active_result = pcall(setTurbineActive, turbine, caps, true)
      if not ok_active then
        warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_control_turbine
      end
      if not active_result then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      local rpm = nil
      if turbine.getRotorSpeed then
        local ok, value = pcall(turbine.getRotorSpeed)
        if ok and type(value) == "number" then
          rpm = value
        end
      end
      local ok_inductor, inductor_result = update_inductor_for_rpm(name, turbine, caps, rpm)
      if not ok_inductor then
        warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
        goto continue_control_turbine
      end
      if not inductor_result then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      local set_ok, result = apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
      if not set_ok then
        warn_once("turbine_flow:" .. name, "Turbine flow update failed for " .. name .. ": " .. tostring(result))
        goto continue_control_turbine
      end
      if not result then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      if not autonom_control_logged then
        autonom_control_logged = true
        log("INFO", "AUTONOM actuator control active")
      end
      ::continue_control_turbine::
    end
  end
end

local allowed_transitions = {
  [STATE.INIT] = { [STATE.AUTONOM] = true, [STATE.MASTER] = true, [STATE.SAFE] = true },
  [STATE.MASTER] = { [STATE.AUTONOM] = true, [STATE.SAFE] = true },
  [STATE.AUTONOM] = { [STATE.MASTER] = true, [STATE.SAFE] = true },
  [STATE.SAFE] = {}
}

local function setState(new_state)
  if current_state == new_state then
    return false
  end
  if not allowed_transitions[current_state] or not allowed_transitions[current_state][new_state] then
    return false
  end
  local previous_state = current_state
  current_state = new_state
  if new_state == STATE.AUTONOM then
    log("INFO", "Entering AUTONOM mode")
  elseif new_state == STATE.MASTER then
    if previous_state == STATE.AUTONOM then
      log("INFO", "Master reconnected")
    else
      log("INFO", "Entering MASTER mode")
    end
  elseif new_state == STATE.SAFE then
    log("INFO", "Entering SAFE mode")
    apply_safe_controls()
    set_reactors_active(false)
    set_turbines_active(false)
  else
    log("INFO", "Entering INIT mode")
  end
  return true
end

local function apply_mode(mode)
  if mode == STATE.AUTONOM then
    if setState(STATE.AUTONOM) then
      node_state_machine:transition(constants.node_states.AUTONOM)
    end
  elseif mode == STATE.MASTER then
    if setState(STATE.MASTER) then
      local current = node_state_machine.state()
      if current == constants.node_states.OFF or current == constants.node_states.AUTONOM then
        node_state_machine:transition(constants.node_states.RUNNING)
      end
    end
  elseif mode == STATE.SAFE then
    setState(STATE.SAFE)
    if node_state_machine.state() ~= constants.node_states.EMERGENCY then
      node_state_machine:transition(constants.node_states.EMERGENCY)
    end
  end
end

cache = function()
  peripherals.reactors = utils.cache_peripherals(config.reactors)
  peripherals.turbines = utils.cache_peripherals(config.turbines)
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

    local methods = peripheral.getMethods(name)
    if methods then
      for _, m in ipairs(methods) do
        log(DEBUG, "  method: " .. m)
      end
    end
  end
end

local function to_set(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[value] = true
  end
  return out
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
  local allow_reactors = to_set(configured_reactors)
  local allow_turbines = to_set(configured_turbines)
  local allow_all_reactors = #configured_reactors == 0
  local allow_all_turbines = #configured_turbines == 0
  local adapter_map = { reactors = {}, turbines = {} }
  local registry_devices = {}

  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      table.insert(registry_devices, {
        name = name,
        type = "monitor",
        methods = peripheral.getMethods(name) or {},
        kind = "monitor",
        bound = monitor_name == name
      })
    end
  end

  for _, name in ipairs(names) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then
      goto continue
    end
    local method_set = {}
    for _, method in ipairs(methods) do
      method_set[method] = true
    end
    local is_reactor = method_set.getControlRodLevel or method_set.setAllControlRodLevels or method_set.getFuelAmount
    local is_turbine = method_set.getRotorSpeed or method_set.getRotorRPM or method_set.setFluidFlowRateMax
    if is_reactor then
      local info = reactor_adapter.inspect(name, CONFIG.LOG_PREFIX)
      if info then
        local bound = allow_all_reactors or allow_reactors[name]
        if bound then
          adapter_map.reactors[name] = info
        end
        table.insert(registry_devices, {
          name = name,
          type = info.type,
          methods = info.methods,
          kind = "reactor",
          bound = bound,
          features = info.features,
          schema = info.schema
        })
      end
    elseif is_turbine then
      local info = turbine_adapter.inspect(name, CONFIG.LOG_PREFIX)
      if info then
        local bound = allow_all_turbines or allow_turbines[name]
        if bound then
          adapter_map.turbines[name] = info
        end
        table.insert(registry_devices, {
          name = name,
          type = info.type,
          methods = info.methods,
          kind = "turbine",
          bound = bound,
          features = info.features,
          schema = info.schema
        })
      end
    end
    ::continue::
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
  for _, module in pairs(modules) do
    if module.type == "turbine" then
      module.peripheral = peripherals.turbines[module.name]
      module.caps = module.peripheral and get_device_caps("turbines", module.name) or nil
    else
      module.peripheral = peripherals.reactors[module.name]
      module.caps = module.peripheral and get_device_caps("reactors", module.name) or nil
    end
  end
end

local function ramp_duration(profile)
  return ramp_profiles[profile] or ramp_profiles.NORMAL
end

local function master_peer_state()
  local peers = comms and comms:get_peers() or {}
  for _, data in pairs(peers) do
    if data.role == constants.roles.MASTER then
      return data
    end
  end
  return nil
end

local function is_master_connected()
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

local function build_health_payload()
  local reasons = {}
  local summary = devices.registry_summary or registry:get_summary()
  local bound_reactors = summary.kinds.reactor and summary.kinds.reactor.bound or 0
  local bound_turbines = summary.kinds.turbine and summary.kinds.turbine.bound or 0
  if bound_reactors == 0 then
    reasons[health.reasons.NO_REACTOR] = true
  end
  if bound_turbines == 0 then
    reasons[health.reasons.NO_TURBINE] = true
  end
  if devices.discovery_failed or devices.registry_load_error then
    reasons[health.reasons.DISCOVERY_FAILED] = true
  end
  if devices.proto_mismatch then
    reasons[health.reasons.PROTO_MISMATCH] = true
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

local function add_alarm(sender, severity, message)
  comms:send_alert(severity, message)
end

local function module_payload()
  local snapshot = {}
  for id, module in pairs(modules) do
    snapshot[id] = {
      state = module.state,
      progress = module.progress,
      limits = module.limits
    }
  end
  return snapshot
end

local function build_turbine_snapshots()
  local list = {}
  for _, entry in ipairs(registry:get_bound_devices("turbine")) do
    local info = turbine_adapter.inspect(entry.name, CONFIG.LOG_PREFIX)
    local module = modules[entry.id]
    table.insert(list, {
      id = entry.id,
      name = entry.name,
      alias = entry.alias,
      rpm = info and info.rpm or nil,
      flow_rate = info and info.flow or nil,
      target_rpm = targets.rpm,
      coil_engaged = info and info.coil_engaged or nil,
      state = module and module.state or nil
    })
  end
  return list
end

local function build_reactor_snapshots()
  local list = {}
  for _, entry in ipairs(registry:get_bound_devices("reactor")) do
    local info = reactor_adapter.inspect(entry.name, CONFIG.LOG_PREFIX)
    local module = modules[entry.id]
    table.insert(list, {
      id = entry.id,
      name = entry.name,
      alias = entry.alias,
      rods_level = info and info.control_rod_level or nil,
      active = info and info.active or nil,
      steam_production = info and info.steam or nil,
      state = module and module.state or nil
    })
  end
  return list
end

local function build_status_payload(status_level)
  local health_payload = build_health_payload()
  local turbines = build_turbine_snapshots()
  local reactors = build_reactor_snapshots()
  return {
    status = status_level,
    state = node_state_machine.state(),
    mode = current_state,
    output = targets.power,
    turbine_rpm = targets.rpm,
    steam = targets.steam,
    capabilities = health_payload.capabilities,
    bindings = health_payload.bindings,
    bindings_summary = health.summarize_bindings(health_payload.bindings),
    health = health_payload,
    modules = module_payload(),
    snapshot = status_snapshot,
    turbines = turbines,
    reactors = reactors,
    registry = {
      summary = devices.registry_summary or registry:get_summary(),
      devices = registry:get_devices_by_kind(),
      diagnostics = registry:get_diagnostics()
    },
    control_mode = current_state,
    ramp_state = { active_module = active_startup, queue = startup_queue }
  }
end

local function broadcast_status(status_level)
  local payload = build_status_payload(status_level)
  comms:publish_status(payload, { requires_ack = true })
end

local function hello()
  local summary = registry:get_summary()
  local caps = {
    reactors = summary.kinds.reactor and summary.kinds.reactor.bound or 0,
    turbines = summary.kinds.turbine and summary.kinds.turbine.bound or 0
  }
  comms:send_hello(caps)
end

set_reactors_active = function(active)
  for name, reactor in pairs(peripherals.reactors) do
    local caps = get_device_caps("reactors", name)
    local ok, result = pcall(setReactorActive, reactor, caps, active)
    if not ok then
      warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(result))
    elseif not result then
      warn_unsupported(name)
    end
  end
end

set_turbines_active = function(active)
  for name, turbine in pairs(peripherals.turbines) do
    local caps = get_device_caps("turbines", name)
    local ok, result = pcall(setTurbineActive, turbine, caps, active)
    if not ok then
      warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(result))
    elseif not result then
      warn_unsupported(name)
    end
  end
end

apply_safe_controls = function()
  for name, reactor in pairs(peripherals.reactors) do
    local caps = get_device_caps("reactors", name)
    if caps.getControlRods or caps.setAllControlRodLevels then
      local ctrl = ensure_reactor_ctrl(name)
      ctrl.last_applied = nil
    else
      warn_unsupported(name)
    end
  end
  applyReactorRods(100, true)

  for name, turbine in pairs(peripherals.turbines) do
    local caps = get_device_caps("turbines", name)
    local rpm = turbine.getRotorSpeed and turbine.getRotorSpeed() or nil
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
      ctrl.flow = clamp_turbine_flow(ctrl.flow)
      local ok, result = pcall(setTurbineFlow, turbine, caps, ctrl.flow)
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

local function scram()
  apply_safe_controls()
  if current_state == STATE.SAFE then
    set_reactors_active(false)
    set_turbines_active(false)
  end
end

local function update_module_limits(module)
  local limits = {}
  if module.type == "turbine" then
    local rpm = module.peripheral and module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or 0
    local target_rpm = get_target_rpm()
    if target_rpm > 0 and rpm > 0 and rpm < target_rpm * 0.7 then
      table.insert(limits, "RPM")
    end
  elseif module.type == "reactor" then
    local temp = module.peripheral and module.peripheral.getCasingTemperature and module.peripheral.getCasingTemperature() or 0
    if temp > config.safety.max_temperature then
      table.insert(limits, "TEMP")
    end
    if reactor_low_water(module.peripheral) then
      table.insert(limits, "WATER")
    end
  end
  module.limits = limits
  return limits
end

local function adjust_reactors()
  if current_state == STATE.MASTER and targets.enable_reactors == false then
    applyReactorRods(100, true)
    set_reactors_active(false)
    return
  end
  local active = 0
  for _, module in pairs(modules) do
    if module.type == "reactor" and module.peripheral and module.state ~= "OFF" and module.state ~= "ERROR" then
      active = active + 1
    end
  end
  for _, module in pairs(modules) do
    if module.type == "reactor" and module.peripheral then
      if module.state == "OFF" or module.state == "ERROR" then
        ensure_reactor_ctrl(module.name)
      else
        if (current_state == STATE.AUTONOM or current_state == STATE.MASTER) and module.caps then
          local ok_active, active_result = pcall(setReactorActive, module.peripheral, module.caps, true)
          if ok_active and not active_result then
            warn_unsupported(module.name)
          end
        end
        local temp = module.peripheral.getCasingTemperature and module.peripheral.getCasingTemperature() or 0
        if temp > config.safety.max_temperature then
          module.state = "ERROR"
          module.progress = 0
          module.limits = { "TEMP" }
          if current_state ~= STATE.SAFE then
            log("ERROR", "Safety trigger: reactor temperature limit exceeded")
            setState(STATE.SAFE)
          end
          if node_state_machine.state() ~= constants.node_states.EMERGENCY then
            node_state_machine:transition(constants.node_states.EMERGENCY)
          end
          return
        end
        if reactor_low_water(module.peripheral) then
          module.state = "ERROR"
          module.progress = 0
          module.limits = { "WATER" }
          if current_state ~= STATE.SAFE then
            log("ERROR", "Safety trigger: reactor coolant level too low")
            setState(STATE.SAFE)
          end
          if node_state_machine.state() ~= constants.node_states.EMERGENCY then
            node_state_machine:transition(constants.node_states.EMERGENCY)
          end
          return
        end
        if not module.caps or not (module.caps.getControlRods or module.caps.setAllControlRodLevels) then
          warn_unsupported(module.name)
          goto continue_adjust_reactor
        elseif module.caps and (module.caps.getControlRods or module.caps.setAllControlRodLevels) then
          ensure_reactor_ctrl(module.name)
        end
      end
    end
    ::continue_adjust_reactor::
  end
end

local function adjust_turbines()
  if current_state == STATE.MASTER and targets.enable_turbines == false then
    set_turbines_active(false)
    return
  end
  local target_rpm = get_target_rpm()
  for _, module in pairs(modules) do
    if module.type == "turbine" and module.peripheral then
      if module.state == "OFF" or module.state == "ERROR" then
        local rpm = module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or nil
        if module.caps and module.caps.setInductorEngaged then
          local ok_inductor, inductor_result = update_inductor_for_rpm(module.name, module.peripheral, module.caps, rpm)
          if not ok_inductor then
            warn_once("turbine_inductor:" .. module.name, "Turbine inductor update failed for " .. module.name .. ": " .. tostring(inductor_result))
          elseif not inductor_result then
            warn_unsupported(module.name)
          end
        end
        if module.caps and (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
          local ctrl = get_turbine_ctrl(module.name)
          ctrl.mode = TURBINE_MODE.RAMP
          ctrl.flow = clamp_turbine_flow(ctrl.flow)
          local ok_flow, flow_result = pcall(setTurbineFlow, module.peripheral, module.caps, ctrl.flow)
          if not ok_flow then
            warn_once("turbine_flow:" .. module.name, "Turbine flow update failed for " .. module.name .. ": " .. tostring(flow_result))
          elseif not flow_result then
            warn_unsupported(module.name)
          end
        end
        local ctrl = get_turbine_ctrl(module.name)
        ctrl.mode = TURBINE_MODE.RAMP
      elseif module.state == "STARTING" then
        goto continue_adjust_turbine
      else
        if not module.caps or not module.caps.setInductorEngaged then
          warn_unsupported(module.name)
          goto continue_adjust_turbine
        end
        if not module.caps or not (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
          warn_unsupported(module.name)
          goto continue_adjust_turbine
        end
        if (current_state == STATE.AUTONOM or current_state == STATE.MASTER) and module.caps then
          local ok_active, active_result = pcall(setTurbineActive, module.peripheral, module.caps, true)
          if ok_active and not active_result then
            warn_unsupported(module.name)
          end
        end
        local rpm = module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or nil
        local ok_inductor, inductor_result = update_inductor_for_rpm(module.name, module.peripheral, module.caps, rpm)
        if not ok_inductor then
          warn_once("turbine_inductor:" .. module.name, "Turbine inductor update failed for " .. module.name .. ": " .. tostring(inductor_result))
          goto continue_adjust_turbine
        end
        if not inductor_result then
          warn_unsupported(module.name)
          goto continue_adjust_turbine
        end
        local ok_flow, flow_result = apply_turbine_flow(module.name, module.peripheral, module.caps, rpm, target_rpm)
        if not ok_flow then
          warn_once("turbine_flow:" .. module.name, "Turbine flow update failed for " .. module.name .. ": " .. tostring(flow_result))
          goto continue_adjust_turbine
        end
        if not flow_result then
          warn_unsupported(module.name)
          goto continue_adjust_turbine
        end
      end
    end
    ::continue_adjust_turbine::
  end
end

local function check_interlocks(module)
  local limits = update_module_limits(module)
  if module.type == "turbine" then
    for _, limit in ipairs(limits) do
      if limit == "WATER" then
        return false, limits
      end
    end
  elseif module.type == "reactor" then
    for _, limit in ipairs(limits) do
      if limit == "TEMP" or limit == "WATER" then
        return false, limits
      end
    end
  end
  if not module.peripheral then
    return false, limits
  end
  return true, limits
end

local function mark_stable(module, now)
  module.state = "STABLE"
  module.progress = 1
  module.stable_since = now
end

local function start_module(module_id, module_type, ramp_profile)
  local module = modules[module_id]
  if not module or module.type ~= module_type then
    return nil, "Unknown module"
  end
  if active_startup and active_startup ~= module_id then
    return nil, "Startup busy"
  end
  if module.state == "STARTING" then
    return module, "Starting"
  end
  if module.state == "STABLE" or module.state == "RUNNING" then
    return module, "Already running"
  end
  module.state = "STARTING"
  module.progress = 0
  module.limits = {}
  module.start_time = os.epoch("utc")
  module.ramp_profile = ramp_profile or "NORMAL"
  module.stable_since = nil
  active_startup = module_id
  if module.type == "turbine" then
    local ctrl = get_turbine_ctrl(module.name)
    ctrl.mode = TURBINE_MODE.RAMP
  end
  return module, "Starting"
end

local function process_startup()
  if not active_startup then return end
  local module = modules[active_startup]
  if not module then
    active_startup = nil
    return
  end
  local ok, limits = check_interlocks(module)
  if not ok then
    module.state = "ERROR"
    module.progress = 0
    module.limits = limits
    active_startup = nil
    add_alarm(comms.network.id, "EMERGENCY", "Startup blocked for " .. module.id)
    return
  end
  local now = os.epoch("utc")
  local duration = ramp_duration(module.ramp_profile)
  local progress = safety.clamp((now - module.start_time) / duration, 0, 1)
  module.progress = progress
  if module.type == "turbine" then
    if module.caps then
      local ok_active, active_result = pcall(setTurbineActive, module.peripheral, module.caps, true)
      if ok_active and not active_result then
        warn_unsupported(module.name)
      end
    end
    if not module.caps or not module.caps.setInductorEngaged then
      warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    if not module.caps or not (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
      warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    local rpm = module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or nil
    local ok_inductor, inductor_result = update_inductor_for_rpm(module.name, module.peripheral, module.caps, rpm)
    if not ok_inductor then
      warn_once("turbine_inductor:" .. module.name, "Turbine inductor update failed for " .. module.name .. ": " .. tostring(inductor_result))
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    if not inductor_result then
      warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    if module.caps and (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
      local target_rpm = get_target_rpm()
      local ctrl = get_turbine_ctrl(module.name)
      local flow, mode = update_turbine_flow_state(rpm, target_rpm, ctrl)
      local ok_flow, flow_result = pcall(setTurbineFlow, module.peripheral, module.caps, ctrl.flow)
      if not ok_flow then
        warn_once("turbine_flow:" .. module.name, "Turbine flow update failed for " .. module.name .. ": " .. tostring(flow_result))
        module.state = "ERROR"
        module.progress = 0
        module.limits = { "CONTROL" }
        active_startup = nil
        return
      end
      if not flow_result then
        warn_unsupported(module.name)
        module.state = "ERROR"
        module.progress = 0
        module.limits = { "CONTROL" }
        active_startup = nil
        return
      end
      if not ctrl.logged then
        log("INFO", "Turbine " .. module.name .. " active, initial flow " .. tostring(ctrl.flow))
        ctrl.logged = true
      end
      log("DEBUG", "Turbine " .. module.name .. " rpm=" .. tostring(rpm) .. " flow=" .. tostring(flow) .. " mode=" .. tostring(mode))
    end
    local target_rpm = get_target_rpm()
    rpm = rpm or 0
    if target_rpm > 0 then
      module.progress = safety.clamp(rpm / target_rpm, 0, 1)
    else
      module.progress = 0
    end
    if rpm >= target_rpm and target_rpm > 0 then
      mark_stable(module, now)
      active_startup = nil
    end
  elseif module.type == "reactor" then
    if module.caps then
      local ok_active, active_result = pcall(setReactorActive, module.peripheral, module.caps, true)
      if ok_active and not active_result then
        warn_unsupported(module.name)
      end
    end
    if not module.caps or not (module.caps.getControlRods or module.caps.setAllControlRodLevels) then
      warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    if module.caps and (module.caps.getControlRods or module.caps.setAllControlRodLevels) then
      local level = 100 - math.floor(progress * 100)
      local ctrl = ensure_reactor_ctrl(module.name)
      ctrl.last_applied = nil
      applyReactorRods(level, false)
    end
    local temp = module.peripheral.getCasingTemperature and module.peripheral.getCasingTemperature() or 0
    if progress >= 1 and temp > 0 and temp < config.safety.max_temperature then
      mark_stable(module, now)
      active_startup = nil
    end
  end
end

local function update_module_states()
  local now = os.epoch("utc")
  for _, module in pairs(modules) do
    local limits = update_module_limits(module)
    if module.type == "reactor" and module.state ~= "OFF" then
      for _, limit in ipairs(limits) do
        if limit == "TEMP" or limit == "WATER" then
          module.state = "ERROR"
          module.progress = 0
          if current_state ~= STATE.SAFE then
            if limit == "WATER" then
              log("ERROR", "Safety trigger: reactor coolant level too low")
            else
              log("ERROR", "Safety trigger: reactor temperature limit exceeded")
            end
            setState(STATE.SAFE)
          end
          if node_state_machine.state() ~= constants.node_states.EMERGENCY then
            node_state_machine:transition(constants.node_states.EMERGENCY)
          end
        end
      end
    end
    if module.state == "STABLE" and module.stable_since and (now - module.stable_since > 3000) then
      if node_state_machine.state() == constants.node_states.RUNNING then
        module.state = "RUNNING"
      end
    end
    if module.state == "RUNNING" and #module.limits > 0 then
      module.state = "LIMITED"
    elseif module.state == "LIMITED" and #module.limits == 0 then
      module.state = "RUNNING"
    end
  end
end

local function monitor_master()
  local connected = is_master_connected()
  if not connected then
    if setState(STATE.AUTONOM) then
      log("WARN", "Master timeout detected, switching to AUTONOM")
      node_state_machine:transition(constants.node_states.AUTONOM)
    end
  end
end

local function clamp_autonom_targets()
  targets.power = 0
  targets.rpm = ramp_towards(targets.rpm, TARGET_RPM, config.autonom.flow_step)
  targets.steam = 0
end

local function note_master_seen()
  master_seen = os.epoch("utc")
end

local function update_status_snapshot()
  local now = os.epoch("utc")
  local interval = (config.status_interval or 5) * 1000
  if now - last_snapshot < interval then
    return status_snapshot
  end
  last_snapshot = now

  local temp_sum, temp_count, temp_max = 0, 0, 0
  for _, name in ipairs(config.reactors) do
    local reactor = peripherals.reactors[name]
    if reactor and reactor.getCasingTemperature then
      local ok, temp = pcall(reactor.getCasingTemperature)
      if ok and type(temp) == "number" then
        temp_sum = temp_sum + temp
        temp_count = temp_count + 1
        if temp > temp_max then
          temp_max = temp
        end
      end
    end
  end

  local rpm_sum, rpm_count = 0, 0
  for _, name in ipairs(config.turbines) do
    local turbine = peripherals.turbines[name]
    if turbine and turbine.getRotorSpeed then
      local ok, rpm = pcall(turbine.getRotorSpeed)
      if ok and type(rpm) == "number" then
        rpm_sum = rpm_sum + rpm
        rpm_count = rpm_count + 1
      end
    end
  end

  local avg_temp = temp_count > 0 and (temp_sum / temp_count) or 0
  local avg_rpm = rpm_count > 0 and (rpm_sum / rpm_count) or 0
  local master_ok = is_master_connected()
  local turbine_details = {}
  for _, name in ipairs(config.turbines) do
    local turbine = peripherals.turbines[name]
    local ctrl = get_turbine_ctrl(name)
    local rpm = nil
    local active = nil
    local coil = ctrl.inductor_engaged
    if turbine and turbine.getRotorSpeed then
      local ok, value = pcall(turbine.getRotorSpeed)
      if ok and type(value) == "number" then
        rpm = value
      end
    end
    if turbine and turbine.getActive then
      local ok, value = pcall(turbine.getActive)
      if ok then
        active = value
      end
    end
    if turbine and turbine.getInductorEngaged then
      local ok, value = pcall(turbine.getInductorEngaged)
      if ok then
        coil = value
      end
    end
    turbine_details[name] = {
      rpm = rpm,
      flow = ctrl.flow,
      coil = coil,
      mode = ctrl.mode,
      active = active
    }
  end

  local reactor_details = {}
  for _, name in ipairs(config.reactors) do
    local reactor = peripherals.reactors[name]
    local rods = nil
    local temp = nil
    local active = nil
    if reactor and reactor.getControlRodLevel then
      local ok, value = pcall(reactor.getControlRodLevel, 0)
      if ok and type(value) == "number" then
        rods = value
      end
    end
    if reactor and reactor.getCasingTemperature then
      local ok, value = pcall(reactor.getCasingTemperature)
      if ok and type(value) == "number" then
        temp = value
      end
    end
    if reactor and reactor.getActive then
      local ok, value = pcall(reactor.getActive)
      if ok then
        active = value
      end
    end
    reactor_details[name] = {
      rods = rods,
      temp = temp,
      active = active
    }
  end

  status_snapshot = {
    node_id = comms and comms.network and comms.network.id or config.role,
    state = current_state,
    master_connected = master_ok,
    reactor_count = #config.reactors,
    turbine_count = #config.turbines,
    avg_temp = avg_temp,
    max_temp = temp_max,
    avg_rpm = avg_rpm,
    turbines = turbine_details,
    reactors = reactor_details,
    timestamp = now
  }

  if config.status_log then
    log("INFO", "Status snapshot updated")
  end

  return status_snapshot
end

local function init_monitor()
  local entry = monitor_adapter.find(nil, "first", config.monitor_scale, CONFIG.LOG_PREFIX)
  monitor = entry and entry.mon or nil
  monitor_name = entry and entry.name or nil
  if monitor then
    pcall(monitor.setBackgroundColor, colors.black)
    pcall(monitor.setTextColor, colors.white)
    pcall(monitor.clear)
  end
end

local function update_monitor()
  if not monitor then return end
  local now = os.epoch("utc")
  if now - last_monitor_update < (config.monitor_interval * 1000) then
    return
  end
  last_monitor_update = now
  if now - last_monitor_page > 8000 then
    monitor_page = monitor_page == 1 and 2 or 1
    last_monitor_page = now
  end
  local snapshot = update_status_snapshot()
  local avg_temp = snapshot and snapshot.avg_temp or 0
  local health_payload = build_health_payload()
  local summary = devices.registry_summary or registry:get_summary()
  local lines = {}
  if monitor_page == 1 then
    lines = {
      "RT Node: " .. (comms and comms.network and comms.network.id or config.node_id or "RT"),
      "State: " .. tostring(current_state),
      "Health: " .. tostring(health_payload.status),
      "Reactors: " .. tostring(summary.kinds.reactor and summary.kinds.reactor.bound or 0),
      "Turbines: " .. tostring(summary.kinds.turbine and summary.kinds.turbine.bound or 0),
      string.format("Avg Temp: %.1f", avg_temp),
      "Target RPM: " .. tostring(get_target_rpm())
    }
  else
    local reasons = table.concat(health_payload.reasons or {}, ",")
    lines = {
      "RT Diagnostics",
      "Registry total: " .. tostring(summary.total or 0),
      "Bound: " .. tostring(summary.bound or 0),
      "Missing: " .. tostring(summary.missing or 0),
      "Reasons: " .. (reasons ~= "" and reasons or "none"),
      "Last scan: " .. (devices.last_scan_ts and (math.floor((now - devices.last_scan_ts) / 1000) .. "s") or "n/a")
    }
  end
  pcall(monitor.setBackgroundColor, colors.black)
  pcall(monitor.setTextColor, colors.white)
  pcall(monitor.clear)
  for i, line in ipairs(lines) do
    pcall(monitor.setCursorPos, 1, i)
    pcall(monitor.write, line)
  end
end

local states = {
  [constants.node_states.OFF] = {
    on_enter = function()
      scram()
      targets.power, targets.steam, targets.rpm = 0, 0, 0
    end,
    on_tick = function()
      monitor_master()
    end
  },
  [constants.node_states.STARTUP] = {
    on_enter = function()
      targets.steam = 0
      targets.rpm = TARGET_RPM
      startup_queue = {}
      for _, entry in ipairs(devices.turbines or {}) do
        table.insert(startup_queue, entry.id)
      end
      for _, entry in ipairs(devices.reactors or {}) do
        table.insert(startup_queue, entry.id)
      end
    end,
    on_tick = function()
      if not active_startup and #startup_queue > 0 then
        local next_id = table.remove(startup_queue, 1)
        local module = modules[next_id]
        if module then
          start_module(module.id, module.type, "NORMAL")
        end
      end
      adjust_turbines()
      adjust_reactors()
      monitor_master()
      if not active_startup and #startup_queue == 0 then
        node_state_machine:transition(constants.node_states.RUNNING)
      end
    end
  },
  [constants.node_states.RUNNING] = {
    on_tick = function()
      adjust_turbines()
      adjust_reactors()
      monitor_master()
    end
  },
  [constants.node_states.LIMITED] = {
    on_tick = function()
      targets.power = targets.power * 0.5
      adjust_reactors()
      adjust_turbines()
      monitor_master()
    end
  },
  [constants.node_states.AUTONOM] = {
    on_enter = function()
      active_startup = nil
      startup_queue = {}
      clamp_autonom_targets()
    end,
    on_tick = function()
      clamp_autonom_targets()
      adjust_reactors()
      adjust_turbines()
      if current_state == STATE.MASTER then
        node_state_machine:transition(constants.node_states.RUNNING)
      end
    end
  },
  [constants.node_states.MANUAL] = {
    on_tick = function()
      monitor_master()
    end
  },
  [constants.node_states.EMERGENCY] = {
    on_enter = function()
      scram()
      targets.power, targets.steam, targets.rpm = 0, 0, 0
      add_alarm(comms.network.id, "EMERGENCY", "SCRAM triggered")
    end,
    on_tick = function()
      monitor_master()
    end
  }
}

local function handle_command(message)
  if not protocol.is_for_node(message, comms.network.id) then return end
  local command = message.payload.command
  if not command or type(command) ~= "table" then
    return { ok = false, error = "invalid command" }
  end
  if current_state == STATE.SAFE then
    return { ok = false, error = "safe: ignoring commands" }
  end
  note_master_seen()
  if command.target == constants.command_targets.SET_MODE then
    local desired = command.value
    apply_mode(desired)
  elseif command.target == constants.command_targets.SET_SETPOINTS then
    if current_state ~= STATE.MASTER then
      return { ok = false, error = "autonom: ignoring setpoints" }
    end
    local value = command.value or {}
    if type(value.target_rpm) == "number" then
      targets.rpm = value.target_rpm
    end
    if type(value.power_target) == "number" then
      targets.power = value.power_target
    end
    if type(value.steam_target) == "number" then
      targets.steam = value.steam_target
    end
    if value.enable_reactors ~= nil then
      targets.enable_reactors = value.enable_reactors and true or false
    end
    if value.enable_turbines ~= nil then
      targets.enable_turbines = value.enable_turbines and true or false
    end
  elseif command.target == constants.command_targets.POWER_TARGET then
    if current_state == STATE.MASTER then
      targets.power = command.value
    end
  elseif command.target == constants.command_targets.STEAM_TARGET then
    if current_state == STATE.MASTER then
      targets.steam = command.value
    end
  elseif command.target == constants.command_targets.TURBINE_RPM then
    if current_state == STATE.MASTER then
      targets.rpm = command.value or TARGET_RPM
    end
  elseif command.target == constants.command_targets.MODE then
    if current_state == STATE.MASTER and states[command.value] then
      node_state_machine:transition(command.value)
    end
  elseif command.target == constants.command_targets.STARTUP_STAGE
    or command.target == constants.command_targets.REQUEST_STARTUP_MODULE then
    if current_state ~= STATE.MASTER then
      return { ok = false, error = "autonom: ignoring startup" }
    end
    local value = command.value or {}
    local module, detail = start_module(value.module_id, value.module_type, value.ramp_profile)
    if not module then
      add_alarm(comms.network.id, "WARNING", "Startup rejected: " .. (detail or "unknown"))
      return { ok = false, error = detail or "startup rejected" }
    end
    return { ok = true, module_id = module.id, detail = detail }
  elseif command.target == constants.command_targets.SCRAM then
    apply_mode(STATE.SAFE)
  end
  return { ok = true }
end

local function send_heartbeat()
  update_status_snapshot()
  comms:send_heartbeat({ state = node_state_machine.state() })
  broadcast_status(constants.status_levels.OK)
  last_heartbeat = os.epoch("utc")
end

local function control_tick()
  refresh_module_peripherals()
  process_startup()
  update_module_states()
  updateReactorControl()
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
  set_reactors_active(true)
  set_turbines_active(true)
  apply_initial_reactor_rods()
  services = service_manager.new({ log_prefix = "RT" })
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
    end
  end
  if os.epoch("utc") - last_heartbeat > hb * 1000 then
    send_heartbeat()
  end
  services:tick()
end
