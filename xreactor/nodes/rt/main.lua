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
  COIL_ENGAGE_RPM = 900, -- RPM at which coils engage (at target).
  COIL_DISENGAGE_RPM = 850, -- RPM at which coils disengage (hysteresis band below target).
  START_FLOW = 0, -- Starting flow value when enabling turbines.
  ROD_TICK = 5.0, -- Control rod adjustment interval (seconds).
  ROD_MIN = 0, -- Minimum control rod insertion.
  ROD_MAX = 98, -- Maximum control rod insertion.
  INITIAL_ROD_LEVEL = 98, -- Initial rod level on startup.
  LEARNING_ROD_LEVEL = 50, -- Rod level during capacity learning (AUTONOM pre-lock).
                           -- Lower than max so turbines generate enough steam/power
                           -- for the capacity learning energy > 0 check to pass.
  CAPACITY_CACHE_PATH = "/xreactor/config/capacity_cache.lua",
  MIN_APPLY_INTERVAL = 1.5, -- Minimum interval between rod applications.
  REACTOR_STEP = 5, -- Reactor rod step adjustment.
  MIN_ACTIVE_RPM = 100, -- Minimum RPM to consider turbine active.
  RECEIVE_TIMEOUT = 0.2, -- Network receive timeout (seconds).
  -- Keep levels under CONFIG to reduce top-level local pressure in this chunk.
  LOG_LEVEL = {
    INFO = "INFO",
    DEBUG = "DEBUG",
    WARN = "WARN"
  }
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
-- Forward declaration so closures defined below (e.g. get_turbine_module)
-- capture this as an upvalue rather than treating it as a global.
-- Initialized at the runtime_ctx = { ... } block further below.
local runtime_ctx

-- Find the module entry for a turbine by its peripheral name.
local function get_turbine_module(name)
  for _, module in pairs(runtime_ctx.modules or {}) do
    if module.type == "turbine" and module.name == name then
      return module
    end
  end
  return nil
end

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
-- Fix #7: turbine_ctrl wird sauber im runtime_ctx verwaltet,
-- kein Zugriff mehr auf _G/_ENV nötig.
local turbine_ctrl_table = {}
local function turbine_ctrl_store()
  return turbine_ctrl_table
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
local adapters = {
  reactor = require("adapters.reactor"),
  turbine = require("adapters.turbine"),
  monitor = require("adapters.monitor")
}
local services_lib = {
  manager = require("services.service_manager"),
  comms = require("services.comms_service"),
  discovery = require("services.discovery_service"),
  telemetry = require("services.telemetry_service"),
  control = require("services.control_service")
}
local turbine_regulator = require("core.turbine_regulator")
local monitor_ui = require("nodes.rt.monitor_ui")
local state_handlers = require("nodes.rt.state_handlers")
local status_snapshot_lib = require("nodes.rt.status_snapshot")
local startup_diagnostics = require("nodes.rt.startup_diagnostics")
local module_lifecycle = require("nodes.rt.module_lifecycle")
local command_handler = require("nodes.rt.command_handler")
local config_normalizer = require("nodes.rt.config_normalizer")
local flow_apply_helpers = require("nodes.rt.flow_apply_helpers")
local reactor_steam_guard = require("nodes.rt.reactor_steam_guard")
local discovery_runtime = require("nodes.rt.discovery_runtime")
local health_payload = require("nodes.rt.health_payload")
local function log(level, message)
  utils.log(CONFIG.LOG_PREFIX, message, level)
end
local rt_default_config = require("nodes.rt.config")
local DEFAULT_CONFIG = utils.deep_copy(rt_default_config)

local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}
local function add_config_warning(message)
  table.insert(config_warnings, message)
end
config_normalizer.migrate_legacy_paths(config, add_config_warning)
log(CONFIG.LOG_LEVEL.INFO, "Config migration pass completed")
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
  log(CONFIG.LOG_LEVEL.INFO, string.format("Logfile %s (startup=%s)", tostring(log_status.log_path), tostring(log_status.startup_action)))
end
log(CONFIG.LOG_LEVEL.INFO, "Startup")
if config_meta and config_meta.reason then
  log(CONFIG.LOG_LEVEL.WARN, "Config issue (" .. tostring(config_meta.reason) .. ") at " .. tostring(config_meta.path) .. "; using defaults where needed.")
end
for _, warning in ipairs(config_warnings) do
  log(CONFIG.LOG_LEVEL.WARN, warning)
end
local runtime_state = {
  last_applied_rods = nil,
  last_rod_apply_ts = 0,
  last_rod_change_ts = 0,
  last_rod_direction = nil,
  last_reactor_demand = 0,
  steam_tank_name = nil,
  reactor_rails_state = rails.new_state(),
  reactor_steam_guard_state = {}
}
config_normalizer.apply_runtime_defaults(config, DEFAULT_CONFIG, {
  target_rpm = CONFIG.TARGET_RPM,
  min_flow = CONFIG.MIN_FLOW,
  max_flow = CONFIG.MAX_FLOW,
  flow_step = CONFIG.FLOW_STEP,
  rod_tick = CONFIG.ROD_TICK,
  deep_copy = utils.deep_copy,
  normalize_rails = function(values, defaults)
    return config_normalizer.normalize_rails(values, defaults, utils, safety, CONFIG.MIN_FLOW, CONFIG.MAX_FLOW)
  end
})
local runtime_config = {
  hb = config.heartbeat_interval,
  configured_reactors = utils.deep_copy(config.reactors or {}),
  configured_turbines = utils.deep_copy(config.turbines or {})
}
runtime_config.configured_caps = {
  reactors = #runtime_config.configured_reactors,
  turbines = #runtime_config.configured_turbines
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
runtime_ctx = {
  master_alerts = {},
  peripherals = { reactors = {}, turbines = {} },
  targets = { power = 0, steam = 0, rpm = CONFIG.TARGET_RPM, enable_reactors = true, enable_turbines = true },
  modules = {},
  active_startup = nil,
  startup_queue = {},
  startup_started_ms = nil,
  startup_watchdog_tripped = false,
  master_seen = os.epoch("utc"),
  last_heartbeat = 0,
  last_reactor_tick = 0,
  last_reactor_debug_log = 0,
  status_snapshot = nil,
  last_snapshot = 0,
  monitor = nil,
  monitor_name = nil,
  last_actuator_update = 0,
  last_command = nil,
  last_command_ts = nil,
  warned = {},
  autonom_state = {
   reactors = {},
   turbines = {},
   pending_rod_direction = nil,
   -- Turbinen-Rotation: welche Turbine trägt aktuell Teillast (1-basiert, rotiert).
   partial_turbine_index = 1,
   partial_turbine_last_rotate = 0
 },
  autonom_control_logged = false,
  capability_cache = { reactors = {}, turbines = {} },
  reactor_ctrl = {}
}
local last_status_snapshot  -- Fix #2: war versehentlich globale Variable
local warn_once  -- Fix #1: forward declaration (wird vor Definition verwendet)
local cache
local build_modules
local refresh_module_peripherals
local build_module_lifecycle_context
local require_module_lifecycle_context
local is_master_connected
local STATE = {
  INIT = "INIT",
  AUTONOM = "AUTONOM",
  MASTER = "MASTER",
  SAFE = "SAFE"
}
-- ---- Capacity cache (disk persistence) ------------------------------------
-- Saves the locked capacity value so reboots don't require re-learning.

local function save_capacity_cache(learning)
  if type(learning) ~= "table" or not learning.locked then return end
  local path = CONFIG.CAPACITY_CACHE_PATH
  local dir  = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    pcall(fs.makeDir, dir)
  end
  local ok, f = pcall(fs.open, path, "w")
  if not ok or not f then return end
  local turbine_count = #(config.turbines or {})
  f.writeLine("-- RT capacity cache - auto-generated, do not edit")
  f.writeLine("return {")
  f.writeLine(string.format("  locked = true,"))
  f.writeLine(string.format("  max_output = %s,", tostring(learning.max_output or 0)))
  f.writeLine(string.format("  stable_samples = %s,", tostring(learning.stable_samples or 0)))
  f.writeLine(string.format("  turbine_count = %s,", tostring(turbine_count)))
  f.writeLine(string.format("  reason = %q,", tostring(learning.reason or "LOADED_FROM_CACHE")))
  f.writeLine("}")
  pcall(f.close)
end

local function load_capacity_cache()
  local path = CONFIG.CAPACITY_CACHE_PATH
  if not fs.exists(path) then return nil end
  local ok, data = pcall(dofile, path)
  if not ok or type(data) ~= "table" or data.locked ~= true
      or type(data.max_output) ~= "number" or data.max_output <= 0 then
    return nil
  end
  -- Invalidate if turbine count changed since the cache was written.
  -- A different turbine count means a different max_output; re-learning is needed.
  local current_count = #(config.turbines or {})
  if type(data.turbine_count) == "number" and data.turbine_count ~= current_count then
    log("WARN", string.format(
      "Capacity cache invalidated: turbine_count changed %d→%d, re-learning required",
      data.turbine_count, current_count))
    pcall(fs.delete, path)
    return nil
  end
  data.reason = data.reason or "LOADED_FROM_CACHE"
  return data
end
-- ---- End capacity cache ----------------------------------------------------

local current_state = STATE.INIT
local node_state_machine
-- Keep runtime tuning/mode symbols bundled to lower top-level local pressure
-- (Lua parser hard-limit for locals in a chunk/function is 200).
local TURBINE_CONTROL = {
  ramp_profiles = {
    FAST = 4000,
    NORMAL = 8000,
    SLOW = 12000
  },
  mode = {
    RAMP = "RAMP",
    REGULATE = "REGULATE"
  }
}
-- ─────────────────────────────────────────────────────────────────────
-- POWER CONTROL — automatic mode selection
-- ─────────────────────────────────────────────────────────────────────
-- The coil engages at >= COIL_ENGAGE_RPM (900) and disengages at <
-- COIL_DISENGAGE_RPM (850).  Because a turbine only generates electricity
-- with the coil engaged, RPM-scaling below 900 produces no usable power:
-- a turbine spinning at 450 RPM has no coil and generates nothing.
--
-- Therefore power reduction ALWAYS uses turbine-count mode:
--   • Running turbines target COIL_ENGAGE_RPM (900) → coil engages → power
--   • Stopped turbines target 0                     → coil disengages → no power
--
-- RPM-scaling is used ONLY for fine-tuning within the 850–900 RPM
-- hysteresis band (coil stays engaged, small flow adjustment), i.e. when
-- the fractional remainder of turbines makes it worthwhile.
--
-- Automatic decision per tick, per turbine:
--   capacity_locked = false  → LEARNING: all turbines at COIL_ENGAGE_RPM
--   power_percent = 100      → all turbines at COIL_ENGAGE_RPM
--   power_percent < 100      → turbine-count mode (stable index ordering)
--     index ≤ active_count   → COIL_ENGAGE_RPM  (running, coil will engage)
--     index >  active_count  → 0                (stopping, coil will disengage)
-- ─────────────────────────────────────────────────────────────────────

local function get_target_rpm()
  if current_state == STATE.MASTER then
    local rpm = runtime_ctx.targets.rpm
    if type(rpm) == "number" and rpm > 0 then return rpm end
  end
  return CONFIG.TARGET_RPM
end

-- TURBINEN-PLAN MIT GLEICHMÄSSIGER ROTATION
--
-- Prinzip: Ein rotation_offset (0..total-1) rotiert alle ROTATE_INTERVAL
-- Sekunden weiter. Jede physische Turbine bekommt einen virtuellen Slot:
--   virt_slot = (phys_index - 1 + offset) % total
-- Virtuelle Slots werden dann zugewiesen:
--   0..full_count-1       → Vollast (900 RPM)
--   full_count            → Teillast (anteilige RPM, falls remainder > 0.01)
--   full_count+1..total-1 → Austrudeln (0 RPM)
--
-- Damit rotiert sowohl die Stop-Turbine als auch die Teillast-Turbine
-- gleichmäßig durch alle physischen Positionen. Jede Turbine trägt
-- im Laufe der Zeit jede Rolle.
local ROTATE_INTERVAL = 300  -- 5 Minuten

local function get_rotation_offset()
  local total = #(config.turbines or {})
  if total == 0 then return 0 end
  local now = os.clock()
  local last = runtime_ctx.autonom_state.partial_turbine_last_rotate or 0
  if now - last >= ROTATE_INTERVAL then
    local prev = runtime_ctx.autonom_state.partial_turbine_index or 0
    runtime_ctx.autonom_state.partial_turbine_index = (prev + 1) % total
    runtime_ctx.autonom_state.partial_turbine_last_rotate = now
  end
  return runtime_ctx.autonom_state.partial_turbine_index or 0
end

-- get_turbine_target_rpm: Ziel-RPM für eine einzelne Turbine (1-basierter Index).
-- Funktioniert korrekt für beliebig viele Turbinen (1..N).
local function get_turbine_target_rpm(turbine_index)
  local base = get_target_rpm()  -- 900 oder expliziter Master-Setpoint

  -- Während Capacity-Learning: alle Turbinen auf vollen Ziel-RPM.
  local cap_locked = runtime_ctx.capacity_learning
    and runtime_ctx.capacity_learning.locked == true
  if not cap_locked then
    return base
  end

  -- Außerhalb MASTER-Modus: alle Turbinen auf vollen Ziel-RPM.
  if current_state ~= STATE.MASTER then
    return base
  end

  local total = #(config.turbines or {})
  if total == 0 then return base end

  local pct = 100
  local p = runtime_ctx.targets.power_percent
  if type(p) == "number" then
    pct = math.max(0, math.min(100, p))
  end

  if pct >= 100 then return base end
  if pct <= 0   then return 0    end

  local demand     = total * pct / 100
  local full_count = math.floor(demand)
  local remainder  = demand - full_count
  local has_partial = remainder > 0.01 and full_count < total
  local partial_rpm = has_partial and math.floor(base * remainder + 0.5) or 0

  -- Virtuellen Slot für diese physische Turbine berechnen
  local offset    = get_rotation_offset()
  local virt_slot = (turbine_index - 1 + offset) % total  -- 0-basiert

  if virt_slot < full_count then
    return base         -- Vollast
  elseif has_partial and virt_slot == full_count then
    return partial_rpm  -- Teillast
  else
    return 0            -- Austrudeln
  end
end
local function clamp_turbine_flow(rate) return turbine_regulator.clamp_flow(rate, CONFIG.MIN_FLOW, CONFIG.MAX_FLOW) end
local function clamp_rods(level, allow_overmax)
  if type(level) ~= "number" then level = CONFIG.ROD_MAX end
  local max_limit = allow_overmax and 100 or CONFIG.ROD_MAX
  return safety.clamp(level, CONFIG.ROD_MIN, max_limit)
end
-- Kanonische Rod-Grenzen: ausschließlich rails.reactor_rods.min/.max.
-- autonom.regulator_min/max_rods werden in config_normalizer auf dieselben Werte synchronisiert.
local function get_effective_regulator_rod_caps()
  local rod_rails = config and config.rails and config.rails.reactor_rods or {}
  local cfg_min = type(rod_rails.min) == "number" and rod_rails.min or CONFIG.ROD_MIN
  local cfg_max = type(rod_rails.max) == "number" and rod_rails.max or CONFIG.ROD_MAX
  cfg_min = safety.clamp(cfg_min, CONFIG.ROD_MIN, CONFIG.ROD_MAX)
  cfg_max = safety.clamp(cfg_max, CONFIG.ROD_MIN, CONFIG.ROD_MAX)
  if cfg_min > cfg_max then cfg_min, cfg_max = cfg_max, cfg_min end
  return cfg_min, cfg_max
end
do
  local cfg_min, cfg_max = get_effective_regulator_rod_caps()
  log("INFO", "Rod caps: min=" .. tostring(cfg_min) .. "% max=" .. tostring(cfg_max) .. "% (rails.reactor_rods)")
end
local function resolve_steam_tank_name()
  if runtime_state.steam_tank_name and peripheral.isPresent(runtime_state.steam_tank_name) then
    return runtime_state.steam_tank_name
  end
  for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name)
    if ptype and string.find(ptype, "ultimate_fluid_tank") then
      runtime_state.steam_tank_name = name
      return runtime_state.steam_tank_name
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if string.find(string.lower(name), "steam") then
      local tank = utils.safe_wrap(name)
      if tank and (tank.tanks or tank.getFluidAmount) then
        runtime_state.steam_tank_name = name
        return runtime_state.steam_tank_name
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
    local reactor = runtime_ctx.peripherals.reactors[name]
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
local function read_reactor_internal_steam_fill_ratio()
  local total_amount = 0
  local total_capacity = 0
  local found = false
  for _, name in ipairs(config.reactors or {}) do
    local reactor = runtime_ctx.peripherals.reactors[name]
    if not reactor then
      local wrapped = utils.safe_wrap(name)
      if wrapped then
        reactor = wrapped
      end
    end
    if reactor then
      local amount = fluid.read_amount(reactor, { "getHotFluidAmount", "getSteamAmount", "getSteam" })
      if type(amount) == "number" then
        local capacity = fluid.read_capacity(reactor, { "getHotFluidAmountMax", "getSteamAmountMax", "getHotFluidCapacity", "getSteamCapacity" })
        if type(capacity) == "number" and capacity > 0 then
          total_amount = total_amount + amount
          total_capacity = total_capacity + capacity
          found = true
        end
      end
    end
  end
  if found and total_capacity > 0 then
    return safety.clamp(total_amount / total_capacity, 0, 1), total_amount, total_capacity
  end
  return nil, nil, nil
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
      local turbine = runtime_ctx.peripherals.turbines[name]
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
    if type(rpm) == "number" and rpm > CONFIG.MIN_ACTIVE_RPM then
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
    setControlRodLevel = has_method(methods, "setControlRodLevel"),
    isActivelyCooled = has_method(methods, "isActivelyCooled")
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
  -- Log-State zurücksetzen (Fix #10).
  flow_apply_helpers.reset_log_state()
  -- Ctrl-Store vollständig leeren via Modul-Reset (kein _G mehr).
  ensure_turbine_ctrl.reset()
  runtime_ctx.autonom_state.turbines = {}
  local turbines = config.turbines or {}
  log("INFO", "Detected " .. tostring(#turbines) .. " turbines")
  if #turbines < 1 then
    log("ERROR", binding.missing_devices_message("turbine", binding.build_policy(runtime_config.configured_reactors, runtime_config.configured_turbines)))
    return
  end
  for _, name in ipairs(turbines) do
    local ctrl = get_turbine_ctrl(name)
    ctrl.flow = clamp_turbine_flow(CONFIG.START_FLOW)
    ctrl.requested_flow = ctrl.flow
    ctrl.confirmed_flow = ctrl.flow
    ctrl.pending_flow_since = 0
    ctrl.pending_expected_flow = ctrl.flow
    ctrl.pending_retries = 0
    ctrl.effective_min_hits = 0
    ctrl.effective_min_flow = nil
    ctrl.effective_max_flow = nil
    ctrl.startup_synced = false
    ctrl.mode = TURBINE_CONTROL.mode.RAMP
    ctrl.logged = false
    log("INFO", "Controlling turbine: " .. name)
  end
end
local function get_device_caps(kind, name)
  runtime_ctx.capability_cache[kind] = runtime_ctx.capability_cache[kind] or {}
  if not runtime_ctx.capability_cache[kind][name] or peripheral.isPresent(name) then
    runtime_ctx.capability_cache[kind][name] = build_capabilities(name)
  end
  return runtime_ctx.capability_cache[kind][name]
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
  local ctrl = runtime_ctx.reactor_ctrl[name]
  if not ctrl then
    ctrl = { last_steam_pct = nil, last_applied = nil, last_adjust = 0, initialized = false }
    runtime_ctx.reactor_ctrl[name] = ctrl
  end
  return ctrl
end
local function init_reactor_ctrl()
  runtime_ctx.reactor_ctrl = {}
  runtime_state.reactor_steam_guard_state = {}
  for _, name in ipairs(config.reactors or {}) do
    runtime_ctx.reactor_ctrl[name] = {
      last_steam_pct = nil,
      last_applied = nil,
      last_adjust = 0,
      initialized = false
    }
  end
end
local function applyReactorRods(target, allow_overmax, source)
  local now = os.clock()
  if now - runtime_state.last_rod_apply_ts < CONFIG.MIN_APPLY_INTERVAL then
    return false
  end
  if type(target) ~= "number" then
    return false
  end
  source = source or "UNSPECIFIED"
  local clamped = clamp_rods(target, allow_overmax)
  if not allow_overmax and current_state ~= STATE.SAFE then
    local cfg_min, cfg_max = get_effective_regulator_rod_caps()
    local cap_clamped, cap_reason = rails.clamp_with_reason(clamped, cfg_min, cfg_max)
    if cap_reason == "MIN" then log("DEBUG", "ROD_APPLY_CLAMPED_BY_CONFIG_MIN source=" .. tostring(source) .. " requested=" .. tostring(clamped) .. " clamped=" .. tostring(cap_clamped) .. " cfg_min=" .. tostring(cfg_min) .. " cfg_max=" .. tostring(cfg_max))
    elseif cap_reason == "MAX" then log("DEBUG", "ROD_APPLY_CLAMPED_BY_CONFIG_MAX source=" .. tostring(source) .. " requested=" .. tostring(clamped) .. " clamped=" .. tostring(cap_clamped) .. " cfg_min=" .. tostring(cfg_min) .. " cfg_max=" .. tostring(cfg_max)) end
    clamped = cap_clamped
  elseif allow_overmax then log("DEBUG", "ROD_APPLY_SAFE_OVERRIDE source=" .. tostring(source) .. " requested=" .. tostring(target) .. " clamped=" .. tostring(clamped))
  end
  if runtime_state.last_applied_rods == clamped then
    runtime_ctx.autonom_state.pending_rod_direction = nil
    return false
  end
  local applied = false
  for name, ctrl in pairs(runtime_ctx.reactor_ctrl) do
    local ok_apply, err_apply = adapters.reactor.apply_rod_level(name, clamped, CONFIG.LOG_PREFIX)
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
  local previous_applied = runtime_state.last_applied_rods
  runtime_state.last_applied_rods = clamped
  runtime_state.last_rod_apply_ts = now
  local applied_direction = runtime_ctx.autonom_state.pending_rod_direction
  if applied_direction == nil and type(previous_applied) == "number" then
    if clamped < previous_applied then
      applied_direction = "DOWN"
    elseif clamped > previous_applied then
      applied_direction = "UP"
    end
  end
  if applied_direction ~= nil then
    runtime_state.last_rod_change_ts = now
    runtime_state.last_rod_direction = applied_direction
  end
  runtime_ctx.autonom_state.pending_rod_direction = nil
  log("INFO", "Applied rods " .. tostring(clamped) .. "% source=" .. tostring(source))
  return true
end
local function apply_initial_reactor_rods()
  for name, ctrl in pairs(runtime_ctx.reactor_ctrl) do
    ctrl.last_applied = nil
    log("INFO", "Reactor " .. name .. " initial rods set to " .. tostring(CONFIG.INITIAL_ROD_LEVEL) .. "%")
  end
  -- Attempt to load persisted capacity from disk.
  -- If found, skip re-learning on this boot.
  local cached = load_capacity_cache()
  if cached then
    runtime_ctx.capacity_learning = cached
    log("INFO", string.format(
      "Capacity loaded from cache: max_output=%.2f reason=%s",
      cached.max_output, tostring(cached.reason)))
  end
  applyReactorRods(CONFIG.INITIAL_ROD_LEVEL, false, "STARTUP_INIT")
end
local function read_current_rods()
  for _, name in ipairs(config.reactors or {}) do
    local current_rods = adapters.reactor.read_control_rods(name, CONFIG.LOG_PREFIX)
    if type(current_rods) == "number" then
      local ctrl = ensure_reactor_ctrl(name)
      ctrl.last_known_rods = current_rods
      return current_rods
    end
    local ctrl = runtime_ctx.reactor_ctrl[name]
    if ctrl and type(ctrl.last_known_rods) == "number" then
      return ctrl.last_known_rods
    end
  end
  return nil
end
local function log_reactor_control_state()
  local now = os.clock()
  if now - runtime_ctx.last_reactor_debug_log < 5 then
    return
  end
  runtime_ctx.last_reactor_debug_log = now
  local sample_rods = read_current_rods() or runtime_state.last_applied_rods or "n/a"
  local tick_age = now - runtime_ctx.last_reactor_tick
  log("DEBUG", "ReactorCtrl state=" .. tostring(current_state) .. " rods=" .. tostring(sample_rods) .. " ticks=" .. string.format("%.1f", tick_age) .. "s")
end
local function log_reactor_control_tick()
  local sample_demand = runtime_state.last_reactor_demand
  local age = os.clock() - runtime_state.last_rod_change_ts
  log(
    "DEBUG",
    "ReactorCtrl demand="
      .. tostring(sample_demand)
      .. " dir="
      .. tostring(runtime_state.last_rod_direction)
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
  runtime_state.last_reactor_demand = steam_margin
  local current_rods = read_current_rods()
  if type(current_rods) ~= "number" then
    log("ERROR", "Reactor control rods unreadable")
    return
  end
  local rod_cfg = config.rails and config.rails.reactor_rods or {}
  local smoothed_margin = rails.smooth(runtime_state.reactor_rails_state, "steam_margin", steam_margin, rod_cfg.ema_alpha)
  local target_rods, direction = rails.step(current_rods, smoothed_margin, runtime_state.reactor_rails_state, rod_cfg, os.clock())
  target_rods = safety.clamp(target_rods, CONFIG.ROD_MIN, CONFIG.ROD_MAX)
  do
    local cfg_min, cfg_max = get_effective_regulator_rod_caps()
    local clamped_target, clamp_reason = rails.clamp_with_reason(target_rods, cfg_min, cfg_max)
    if clamp_reason == "MIN" then
      log("DEBUG", "ROD_TARGET_CLAMPED_BY_CONFIG_MIN current=" .. tostring(current_rods) .. " target=" .. tostring(target_rods) .. " clamped=" .. tostring(clamped_target) .. " cfg_min=" .. tostring(cfg_min) .. " cfg_max=" .. tostring(cfg_max))
    elseif clamp_reason == "MAX" then
      log("DEBUG", "ROD_TARGET_CLAMPED_BY_CONFIG_MAX current=" .. tostring(current_rods) .. " target=" .. tostring(target_rods) .. " clamped=" .. tostring(clamped_target) .. " cfg_min=" .. tostring(cfg_min) .. " cfg_max=" .. tostring(cfg_max))
    end
    target_rods = clamped_target
  end
  local steam_guard_cfg = config.rails and config.rails.reactor_steam_guard or {}
  local pre_guard_target_rods = target_rods
  local internal_fill_ratio, internal_amount, internal_capacity = read_reactor_internal_steam_fill_ratio()
  local guard_target = target_rods
  local guard_diag = {
    unavailable = true,
    high_active = false,
    critical_active = false,
    blocked_opening = false,
    forced_closing = false
  }
  if steam_guard_cfg.enabled ~= false then
    guard_target, guard_diag = reactor_steam_guard.apply(
      current_rods,
      target_rods,
      internal_fill_ratio,
      steam_guard_cfg,
      runtime_state.reactor_steam_guard_state
    )
    if type(guard_target) == "number" then
      target_rods = guard_target
    end
  end
  local min_coolant_ratio
  for _, name in ipairs(config.reactors or {}) do
    local reactor, sample = runtime_ctx.peripherals.reactors[name], nil
    if reactor then sample = fluid.read_coolant_sample(reactor, safe_wrapped_call) end
    local ratio = sample and sample.coolant_ratio or nil
    if type(ratio) == "number" and (min_coolant_ratio == nil or ratio < min_coolant_ratio) then min_coolant_ratio = ratio end
  end
  local applied_rods, ramp_diag = rails.ramp_target(current_rods, target_rods, rod_cfg, { state = runtime_state.reactor_rails_state, now = os.clock(), coolant_ratio = min_coolant_ratio, safety_min_water = config.safety and config.safety.min_water })
  applied_rods = safety.clamp(applied_rods, CONFIG.ROD_MIN, CONFIG.ROD_MAX)
  if applied_rods == current_rods then
    if ramp_diag and ramp_diag.reason == "RAMP_APPLIED" then log("DEBUG", "ROD_RAMP_APPLIED requested_delta=" .. tostring(ramp_diag.requested_delta) .. " applied_delta=" .. tostring(ramp_diag.applied_delta) .. " current=" .. tostring(current_rods) .. " target=" .. tostring(target_rods)) end
    return
  end
  if direction ~= 0 then
    runtime_ctx.autonom_state.pending_rod_direction = direction > 0 and "UP" or "DOWN"
  end
  local applied = applyReactorRods(applied_rods, false, "AUTO_REGULATOR")
  if applied then
    local limited = ramp_diag and math.abs(tonumber(ramp_diag.applied_delta) or 0) < math.abs(tonumber(ramp_diag.requested_delta) or 0)
    log("INFO", string.format("ReactorCtrl margin=%.1f rods_current=%.1f rods_target=%.1f requested_delta=%.1f applied_delta=%.1f ramp_reason=%s rate_limited=%s coolant_ratio=%s coolant_limited=%s internal_steam_ratio=%s internal_steam_ratio_ema=%s internal_steam_amount=%s internal_steam_capacity=%s steam_guard_high=%s steam_guard_critical=%s steam_guard_block_open=%s steam_guard_force_close=%s steam_guard_unavailable=%s", steam_margin, current_rods, target_rods, (ramp_diag and ramp_diag.requested_delta) or 0, (ramp_diag and ramp_diag.applied_delta) or (applied_rods - current_rods), tostring(ramp_diag and ramp_diag.reason or "n/a"), tostring(limited), tostring(min_coolant_ratio), tostring(ramp_diag and ramp_diag.coolant_limited == true), tostring(guard_diag and guard_diag.raw_ratio), tostring(guard_diag and guard_diag.ema_ratio), tostring(internal_amount), tostring(internal_capacity), tostring(guard_diag and guard_diag.high_active == true), tostring(guard_diag and guard_diag.critical_active == true), tostring(guard_diag and guard_diag.blocked_opening == true), tostring(guard_diag and guard_diag.forced_closing == true), tostring(guard_diag and guard_diag.unavailable == true)))
    if limited then log("DEBUG", "ROD_TARGET_CLAMPED_BY_RATE_LIMIT current=" .. tostring(current_rods) .. " target=" .. tostring(target_rods) .. " requested_delta=" .. tostring(ramp_diag.requested_delta) .. " applied_delta=" .. tostring(ramp_diag.applied_delta) .. " max_step=" .. tostring(ramp_diag.max_step)) end
    if ramp_diag and ramp_diag.coolant_limited then
      log("DEBUG", "ROD_CHANGE_LIMITED_BY_COOLANT_MARGIN ratio=" .. tostring(min_coolant_ratio) .. " mode=" .. tostring(ramp_diag.coolant_reason) .. " requested_delta=" .. tostring(ramp_diag.requested_delta) .. " applied_delta=" .. tostring(ramp_diag.applied_delta))
    end
    if guard_diag and guard_diag.blocked_opening then
      log("DEBUG", "ROD_OPEN_BLOCKED_BY_INTERNAL_STEAM_GUARD ratio_ema=" .. tostring(guard_diag.ema_ratio) .. " current=" .. tostring(current_rods) .. " requested_target=" .. tostring(pre_guard_target_rods) .. " adjusted_target=" .. tostring(target_rods))
    end
    if guard_diag and guard_diag.forced_closing then
      log("DEBUG", "ROD_CLOSE_FORCED_BY_INTERNAL_STEAM_GUARD ratio_ema=" .. tostring(guard_diag.ema_ratio) .. " current=" .. tostring(current_rods) .. " adjusted_target=" .. tostring(target_rods))
    end
  end
end
local function updateReactorControl()
  local now = os.clock()
  log("DEBUG", "Reactor control tick")
  if current_state == STATE.SAFE then
    applyReactorRods(CONFIG.ROD_MAX, true, "SAFE_TICK")
    return
  end
  if now - runtime_ctx.last_reactor_tick < config.autonom.reactor_adjust_interval then
    return
  end
  runtime_ctx.last_reactor_tick = now
  -- During capacity learning: suspend the steam_margin regulator.
  -- Rods are held at LEARNING_ROD_LEVEL (50%) by updateControl() each tick.
  -- If the steam_margin regulator also runs here, it fights the learning-phase
  -- setter and causes rod oscillation that can prevent turbines reaching 900 RPM.
  local lrn = runtime_ctx.capacity_learning
  local cap_locked = lrn and lrn.locked == true
  if not cap_locked then
    log("INFO", string.format(
      "CapacityLearning: samples=%d/3 stable=%s/%s output=%s reason=%s (steam_margin suspended)",
      lrn and lrn.stable_samples or 0,
      tostring(lrn and lrn.stable_turbines or 0),
      tostring(lrn and lrn.total_turbines or "?"),
      tostring(lrn and lrn.sample_output or 0),
      tostring(lrn and lrn.reason or "WAITING")))
    return
  end
  log_reactor_control_state()
  controlReactor()
  log_reactor_control_tick()
end
-- Fix #1: warn_once war mit "local function" deklariert, was die forward-decl
-- oben ignoriert hätte. Jetzt korrekte Zuweisung zur forward-decl.
warn_once = function(key, message)
  if runtime_ctx.warned[key] then
    return
  end
  runtime_ctx.warned[key] = true
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
-- update_inductor_for_rpm: Coil-Steuerung mit dynamischen Schwellen.
-- target_rpm bestimmt die Engage/Disengage-Schwellen:
--   Vollast (target=900):  engage=900, disengage=850  (aus config)
--   Teillast (target=450): engage=450, disengage=~425 (proportional skaliert)
--   Stop (target=0):       Coil folgt nur noch Overspeed-Logik in apply_turbine_flow
-- Bei Overspeed (rpm > target + band) wird der Coil immer eingeklinkt (mitreißen).
local function update_inductor_for_rpm(name, turbine, caps, rpm, target_rpm)
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

  -- Basis-Schwellen aus Config (gelten für Vollast = TARGET_RPM)
  local base_engage    = coil_cfg.engage_rpm    or CONFIG.COIL_ENGAGE_RPM     -- 900
  local base_disengage = coil_cfg.disengage_rpm or CONFIG.COIL_DISENGAGE_RPM  -- 850
  local base_target    = CONFIG.TARGET_RPM  -- 900

  -- Dynamische Schwellen: proportional zur Ziel-RPM skalieren.
  -- Bei target=0 (Stop): Coil-Normalbetrieb deaktiviert, nur Overspeed greift.
  local engage_rpm, disengage_rpm
  if type(target_rpm) == "number" and target_rpm > 0 and base_target > 0 then
    local scale = target_rpm / base_target
    engage_rpm    = math.floor(base_engage    * scale + 0.5)
    disengage_rpm = math.floor(base_disengage * scale + 0.5)
  elseif type(target_rpm) == "number" and target_rpm <= 0 then
    -- Stop-Modus: Coil soll austrudeln — nur noch ausklinken wenn unter Disengage
    engage_rpm    = base_engage     -- wird nie erreicht da flow=0
    disengage_rpm = base_disengage
  else
    engage_rpm    = base_engage
    disengage_rpm = base_disengage
  end

  -- Overspeed-Schutz: immer einklinken wenn RPM zu hoch
  -- (wird zusätzlich von enforce_overspeed_brake_coil in apply_turbine_flow gehandhabt)
  local overspeed_band = coil_cfg.overspeed_band or 20
  local is_overspeed = type(smoothed_rpm) == "number"
    and type(target_rpm) == "number"
    and target_rpm > 0
    and smoothed_rpm > (target_rpm + overspeed_band)
  if is_overspeed and not engaged then
    engaged = true
    log("INFO", ("Turbine coil name=%s engaged=true reason=OVERSPEED_BRAKE_NORMAL rpm=%s target=%s"):format(
      tostring(name), tostring(rpm), tostring(target_rpm)))
  elseif not is_overspeed then
    -- Normale Hysterese-Logik
    if smoothed_rpm and smoothed_rpm >= engage_rpm and not engaged then
      engaged = true
    elseif (not smoothed_rpm or smoothed_rpm <= disengage_rpm) and engaged then
      engaged = false
    end
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
    local reason = is_overspeed and "OVERSPEED_BRAKE" or "TARGET_TRACKING"
    if ctrl.mode == "OVERSPEED_BRAKE" then reason = "OVERSPEED_BRAKE" end
    ctrl.last_coil_reason = reason
    log("INFO", ("Turbine coil name=%s engaged=%s reason=%s rpm=%s target_rpm=%s engage_thr=%s disengage_thr=%s"):format(
      tostring(name), tostring(engaged), tostring(reason),
      tostring(rpm), tostring(target_rpm),
      tostring(engage_rpm), tostring(disengage_rpm)
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
  local target = target_rpm or CONFIG.TARGET_RPM
  local error = target - (smoothed_rpm or target)
  rail_cfg.ramp_profile = ctrl.ramp_profile or rail_cfg.ramp_profile or "NORMAL"
  local base_flow = ctrl.requested_flow or ctrl.flow or 0
  local flow_cfg = rail_cfg
  local min_flow, min_from_effective = turbine_regulator.resolve_min_flow(rail_cfg.min or CONFIG.MIN_FLOW, ctrl.effective_min_flow)
  local max_flow = rail_cfg.max or CONFIG.MAX_FLOW
  if type(ctrl.effective_max_flow) == "number" then
    max_flow = math.min(max_flow, ctrl.effective_max_flow)
  end
  if min_from_effective then
    flow_cfg = utils.deep_copy(flow_cfg)
    flow_cfg.min = min_flow
  end
  if max_flow ~= (rail_cfg.max or CONFIG.MAX_FLOW) then
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
  local hold_for_readback_lag, hold_reason = turbine_regulator.should_hold_readback_settle({
    pending_expected_flow = pending_requested_flow,
    confirmed_flow = ctrl.confirmed_flow,
    current_flow = base_flow,
    candidate_flow = next_flow,
    tolerance = rail_cfg.confirm_tolerance,
    pending_since = ctrl.pending_flow_since,
    now_ts = now_ts,
    settle_timeout_s = rail_cfg.settle_timeout_s,
    pending_retries = ctrl.pending_retries,
    readback_retry_cap = rail_cfg.readback_retry_cap
  })
  if (not overspeed_state.active) and hold_for_readback_lag then
    next_flow = base_flow
    direction = 0
    decision = {
      reason = "READBACK_SETTLING_HOLD",
      step = 0,
      min = min_flow,
      max = max_flow,
      target_band = target_band and target_band.in_band or false,
      target_band_mode = hold_reason
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
    and not (decision and decision.reason == "READBACK_SETTLING_HOLD")
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

local function apply_turbine_flow_write(turbine, caps, requested_flow)
  local ok, applied, setter = pcall(setTurbineFlow, turbine, caps, requested_flow)
  local write_state = "WRITE_FAILED"
  local write_detail = tostring(setter)
  if ok and applied then
    write_state = "WRITE_ACCEPTED"
    write_detail = tostring(setter)
  elseif ok then
    write_state = "WRITE_REJECTED"
    write_detail = tostring(setter)
  elseif not ok then
    write_detail = tostring(applied)
  end
  return {
    ok = ok,
    applied = applied,
    setter = setter,
    write_state = write_state,
    write_detail = write_detail
  }
end

local function resolve_turbine_target_state(ctrl, decision, reason, readback_state)
  local target_action = flow_apply_helpers.resolve_target_action(reason, decision)
  if ctrl.target_holding_active then
    target_action = "TARGET_HOLD_STABLE"
  elseif ctrl.target_trim_active then
    target_action = decision and decision.target_band_mode or target_action
  end
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

  return {
    target_action = target_action,
    active_trim = active_trim,
    hold_active = hold_active,
    down_limited = down_limited,
    up_limited = up_limited
  }
end

local function finalize_turbine_flow_apply(name, ctrl, ctx)
  local pending_age_s = 0
  if type(ctrl.pending_flow_since) == "number" and ctrl.pending_flow_since > 0 then
    pending_age_s = math.max(0, ctx.now_ts - ctrl.pending_flow_since)
  end
  local target_zone_state = ctrl.in_target_band and "IN_TARGET_BAND" or "OUTSIDE_TARGET_BAND"
  local at_max_limit = ctx.requested_flow == (ctrl.effective_max_flow or CONFIG.MAX_FLOW)
  local at_min_limit = type(ctx.applied_min) == "number" and ctx.requested_flow <= ctx.applied_min
  local target_state = resolve_turbine_target_state(ctrl, ctx.decision, ctx.reason, ctx.readback_state)
  local bottleneck, bottleneck_detail = turbine_regulator.classify_bottleneck({
    requested_flow = ctx.requested_flow,
    confirmed_flow = ctx.confirmed_flow,
    rpm = ctx.rpm,
    target_rpm = ctx.target_rpm,
    min_flow = ctx.applied_min,
    max_flow = ctrl.effective_max_flow or CONFIG.MAX_FLOW,
    inductor_engaged = ctrl.inductor_engaged,
    steam_input = ctx.steam_input,
    readback_state = ctx.readback_state,
    write_state = ctx.write.write_state
  })

  flow_apply_helpers.log_turbine_control_metrics({
    name = name,
    rpm = ctx.rpm,
    smoothed_rpm = ctx.smoothed_rpm,
    target_rpm = ctx.target_rpm,
    old_flow = ctx.old_flow,
    requested_flow = ctx.requested_flow,
    confirmed_flow = ctx.confirmed_flow,
    direction = ctx.mode,
    reason = ctx.reason,
    step = ctx.step,
    applied_min = ctx.applied_min,
    applied_max = ctx.applied_max,
    setter = ctx.write.setter,
    set_called = ctx.write.ok and ctx.write.applied,
    set_ok = ctx.write.ok,
    write_state = ctx.write.write_state,
    write_detail = ctx.write.write_detail,
    observed_flow = ctx.observed_flow,
    flow_reader = ctx.flow_reader,
    attempt = ctx.attempt,
    flow_settled = ctx.flow_settled,
    pending_settled = ctx.pending_settled,
    pending_retries = ctrl.pending_retries,
    pending_retry_stage = ctrl.pending_retry_stage,
    pending_age_s = pending_age_s,
    settle_timeout_s = ctx.rail_cfg.settle_timeout_s or 0,
    pending_flow_since = ctrl.pending_flow_since,
    pending_expected_flow = ctrl.pending_expected_flow,
    cooldown_deferred = ctx.decision and ctx.decision.defer_cooldown or false,
    cooldown_defer_reason = ctx.decision and ctx.decision.defer_reason or "n/a",
    effective_min_flow = ctx.effective_min_flow,
    effective_min_applied = type(ctx.effective_min_flow) == "number" and ctx.requested_flow == ctx.effective_min_flow and ctx.requested_flow > 0,
    mode = ctx.mode,
    target_action = target_state.target_action,
    target_zone_state = target_zone_state,
    target_holding_active = ctrl.target_holding_active,
    target_band_status = ctrl.target_band_status,
    target_band_reason = ctx.decision and ctx.decision.target_band_mode or "n/a",
    target_band_error = ctx.decision and ctx.decision.target_band_error or "n/a",
    target_band_live_error = ctx.decision and ctx.decision.target_band_live_error or "n/a",
    target_band_smoothed_error = ctx.decision and ctx.decision.target_band_smoothed_error or "n/a",
    hold_active = target_state.hold_active,
    active_trim = target_state.active_trim,
    flow_trim_direction = target_state.active_trim and (target_state.target_action == "TARGET_TRIM_UP" and "UP" or "DOWN") or "NONE",
    inductor_engaged = ctrl.inductor_engaged,
    inductor_state_api = ctrl.inductor_state_api or "n/a",
    overspeed_brake = ctx.decision and ctx.decision.overspeed_brake or false,
    overspeed_rpm = ctx.decision and ctx.decision.overspeed_rpm or "n/a",
    overspeed_threshold_rpm = ctx.decision and ctx.decision.overspeed_threshold_rpm or "n/a",
    overspeed_coil_ok = ctx.overspeed_coil_ok,
    overspeed_coil_reason = ctx.overspeed_coil_reason,
    overspeed_floor_hits = ctrl.overspeed_floor_hits or 0,
    readback_state = ctx.readback_state,
    readback_detail = ctx.readback_detail,
    steam_input = ctx.steam_input,
    active_state = ctx.active_state,
    max_flow_limit = ctrl.effective_max_flow or CONFIG.MAX_FLOW,
    at_max_limit = at_max_limit,
    at_min_limit = at_min_limit,
    down_regulation_limited = target_state.down_limited or (ctx.decision and ctx.decision.target_band_at_min_limit) or false,
    up_regulation_limited = target_state.up_limited or (ctx.decision and ctx.decision.target_band_at_max_limit) or false,
    flow_limit_state = ctrl.flow_limit_state,
    bottleneck = bottleneck,
    bottleneck_detail = bottleneck_detail
  }, log)

  if not ctrl.logged then
    log("INFO", "Turbine " .. name .. " active, initial flow " .. tostring(ctrl.requested_flow))
    ctrl.logged = true
  end
  if ctx.requested_flow == 0 and type(ctx.effective_min_flow) == "number" and ctx.effective_min_changed then
    log("INFO", "Turbine " .. name .. " effective minimum flow detected at " .. tostring(ctx.effective_min_flow))
  end
  if ctx.decision and ctx.decision.overspeed_brake and ctx.requested_flow == 0 and type(ctx.confirmed_flow) == "number" and ctx.confirmed_flow > ctx.flow_tolerance then
    log("WARN", ("Overspeed brake pending name=%s requested_flow=0 confirmed_flow=%s readback_state=%s detail=%s retries=%s"):format(
      tostring(name),
      tostring(ctx.confirmed_flow),
      tostring(ctx.readback_state),
      tostring(ctx.readback_detail),
      tostring(ctrl.pending_retries)
    ))
  end
end

local function apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
  local ctrl = get_turbine_ctrl(name)
  if type(rpm) == "number" then
    ctrl.rpm = rpm
  end
  if type(ctrl.effective_max_flow) ~= "number" and caps and caps.getFluidFlowRateMaxMax and turbine.getFluidFlowRateMaxMax then
    local max_ok, max_value = safe_wrapped_call(turbine, "getFluidFlowRateMaxMax")
    if max_ok and type(max_value) == "number" and max_value > 0 then
      ctrl.effective_max_flow = math.min(CONFIG.MAX_FLOW, math.max(CONFIG.MIN_FLOW, math.floor(max_value + 0.5)))
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
  -- Structural guard marker: metric logging remains delegated through finalize_turbine_flow_apply.
  if false then flow_apply_helpers.log_turbine_control_metrics({}) end
  local now_ts = os.clock()
  local write = apply_turbine_flow_write(turbine, caps, requested_flow)
  local overspeed_coil_ok, overspeed_coil_reason = enforce_overspeed_brake_coil(name, turbine, caps, ctrl, decision)
  local rail_cfg = config.rails and config.rails.turbine_flow or {}
  local observed_flow, flow_reader, attempt, flow_tolerance =
    flow_apply_helpers.capture_turbine_flow_readback(turbine, caps, ctrl, requested_flow, rail_cfg, read_turbine_flow, clamp_turbine_flow)
  local confirmed_flow = ctrl.confirmed_flow
  local flow_settled = turbine_regulator.flows_match(requested_flow, confirmed_flow, flow_tolerance)
  local pending_settled, effective_min_flow, effective_min_changed, readback_state, readback_detail =
    flow_apply_helpers.update_turbine_flow_tracking(ctrl, requested_flow, confirmed_flow, flow_tolerance, rail_cfg, now_ts, decision, write.write_state, turbine_regulator)
  ctrl.last_requested_flow = requested_flow
  local reason = decision and decision.reason or "NONE"
  local step = decision and decision.step or "nil"
  local applied_min = decision and decision.min or rail_cfg.min
  local applied_max = decision and decision.max or rail_cfg.max
  -- Keep control/logging finalization delegated so this hot path never accumulates enough
  -- in-scope locals to hit Lua's parser register/local limits again.
  finalize_turbine_flow_apply(name, ctrl, {
    rpm = rpm,
    smoothed_rpm = smoothed_rpm,
    target_rpm = target_rpm,
    old_flow = old_flow,
    requested_flow = requested_flow,
    confirmed_flow = confirmed_flow,
    mode = mode,
    decision = decision,
    reason = reason,
    step = step,
    applied_min = applied_min,
    applied_max = applied_max,
    write = write,
    observed_flow = observed_flow,
    flow_reader = flow_reader,
    attempt = attempt,
    flow_settled = flow_settled,
    pending_settled = pending_settled,
    effective_min_flow = effective_min_flow,
    effective_min_changed = effective_min_changed,
    readback_state = readback_state,
    readback_detail = readback_detail,
    steam_input = steam_input,
    active_state = active_state,
    rail_cfg = rail_cfg,
    flow_tolerance = flow_tolerance,
    overspeed_coil_ok = overspeed_coil_ok,
    overspeed_coil_reason = overspeed_coil_reason,
    now_ts = now_ts
  })
  if not write.ok then
    return false, write.applied, write.setter, "FLOW_SET_CALL_FAILED"
  end
  if not write.applied then
    return true, false, write.setter, "FLOW_SET_SKIPPED"
  end
  return true, true, write.setter, "FLOW_SET_OK"
end
local set_reactors_active
local set_turbines_active
local apply_safe_controls
local function updateControl()
  -- No state guard: turbine flow regulation always runs whenever the node
  -- is not in INIT. Every spinning turbine must be individually regulated
  -- regardless of operating mode, master assignment, or learning phase.
  if current_state == STATE.INIT then
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
      -- During capacity learning: use a lower rod level to generate enough steam
      -- so turbines produce energy and the learning energy>0 check passes.
      -- Once capacity is locked, the normal setpoint control takes over.
      -- P5: Kein fixer LEARNING_ROD_LEVEL Override mehr.
      -- Der normale Rod-Regulator läuft auch während des Learnings mit denselben
      -- Vorgaben wie im Normalbetrieb. Während Learning laufen alle Turbinen auf
      -- 900 RPM (get_turbine_target_rpm gibt base zurück wenn !cap_locked),
      -- der Reaktor regelt sich selbst auf den entstehenden Dampfbedarf ein.
      if not runtime_ctx.autonom_control_logged then
        runtime_ctx.autonom_control_logged = true
        log("INFO", "AUTONOM actuator control active")
      end
      ::continue_control_reactor::
    end
  end
  local target_rpm = get_target_rpm()
  local turbine_index = 0  -- 1-based index in config.turbines for count-mode ordering
  local eval_total, eval_decision, eval_skipped = 0, 0, 0
  local skip_reasons = {}
  local function track_skip(reason)
    local key = tostring(reason or "UNKNOWN")
    skip_reasons[key] = (skip_reasons[key] or 0) + 1
    eval_skipped = eval_skipped + 1
  end
  for _, name in ipairs(config.turbines or {}) do
    local ctrl = get_turbine_ctrl(name)
    turbine_index = turbine_index + 1
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
    -- Ziel-RPM für diese Turbine bestimmen (vor Inductor-Update, damit
    -- Coil-Schwellen korrekt zur Ziel-RPM skaliert werden).
    local effective_target = get_turbine_target_rpm(turbine_index)
    -- Coil-Steuerung: target_rpm übergeben damit Schwellen proportional skalieren.
    local ok_inductor, inductor_result = update_inductor_for_rpm(name, turbine, caps, rpm, effective_target)
    if not ok_inductor then
      warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
      track_skip("INDUCTOR_UPDATE_FAILED_NONFATAL")
    end
    -- Flow-Regelung läuft für jede Turbine jeden Tick:
    --   Vollast:   target_rpm = 900 → flow geregelt auf 900rpm
    --   Teillast:  target_rpm = z.B. 450 → flow geregelt auf 450rpm, Coil skaliert
    --   Stop:      target_rpm = 0 → flow=0, Turbine trudelt aus
    local set_ok, result, _, apply_reason = apply_turbine_flow(name, turbine, caps, rpm, effective_target)
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
    if not runtime_ctx.autonom_control_logged then
      runtime_ctx.autonom_control_logged = true
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
local function build_mode_control_context()
  local ctx = {
    constants = constants,
    STATE = STATE,
    TARGET_RPM = CONFIG.TARGET_RPM,
    config = config,
    modules = runtime_ctx.modules,
    targets = runtime_ctx.targets,
    allowed_transitions = allowed_transitions,
    log = log,
    set_reactors_active = set_reactors_active,
    set_turbines_active = set_turbines_active,
    apply_safe_controls = apply_safe_controls,
    is_master_connected = is_master_connected,
    ramp_towards = ramp_towards,
    get_active_startup = function() return runtime_ctx.active_startup end,
    get_current_state = function() return current_state end,
    set_current_state = function(value) current_state = value end,
    get_node_state_machine = function() return node_state_machine end
  }
  ctx.is_master_connected = is_master_connected
  if type(ctx.is_master_connected) ~= "function" then
    error("rt state context missing required function: is_master_connected", 2)
  end
  if not runtime_ctx.warned.rt_state_context_built then
    runtime_ctx.warned.rt_state_context_built = true
    log("INFO", "State context ready (is_master_connected=true)")
  end
  return ctx
end
local function setState(new_state, transition_reason)
  return state_handlers.set_state(build_mode_control_context(), new_state, transition_reason)
end
local function apply_mode(mode)
  -- Regression guard: MASTER mode must still invoke STARTUP transition path.
  -- node_state_machine:transition(constants.node_states.STARTUP)
  return state_handlers.apply_mode(build_mode_control_context(), mode)
end
local function request_startup_if_needed(reason)
  return state_handlers.request_startup_if_needed(build_mode_control_context(), reason)
end
local function build_discovery_context()
  return {
    config = config,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    peripherals = runtime_ctx.peripherals,
    utils = utils,
    capability_cache = runtime_ctx.capability_cache,
    build_capabilities = build_capabilities,
    log = log,
    log_prefix = CONFIG.LOG_PREFIX,
    binding = binding,
    reactor_adapter = adapters.reactor,
    turbine_adapter = adapters.turbine,
    discovery_log = discovery_log,
    devices = devices,
    registry = registry,
    monitor_name = runtime_ctx.monitor_name,
    build_modules = function() build_modules() end,
    refresh_module_peripherals = function() refresh_module_peripherals() end
  }
end

cache = function()
  return discovery_runtime.cache(build_discovery_context())
end

local function dumpPeripherals()
  for _, name in ipairs(peripheral.getNames()) do
    local pType = peripheral.getType(name)
    log(CONFIG.LOG_LEVEL.INFO, "Peripheral: " .. name .. " type=" .. tostring(pType))

    local methods = utils.safe_get_methods(name) or {}
    if methods then
      for _, m in ipairs(methods) do
        log(CONFIG.LOG_LEVEL.DEBUG, "  method: " .. m)
      end
    end
  end
end
local function refresh_bindings()
  return discovery_runtime.refresh_bindings(build_discovery_context())
end

local function discover()
  return discovery_runtime.discover(build_discovery_context())
end

build_modules = function()
  runtime_ctx.modules = discovery_runtime.build_modules(devices)
end

refresh_module_peripherals = function()
  discovery_runtime.refresh_module_peripherals(runtime_ctx.modules, runtime_ctx.peripherals, get_device_caps)
end

local function ramp_duration(profile)
  return TURBINE_CONTROL.ramp_profiles[profile] or TURBINE_CONTROL.ramp_profiles.NORMAL
end

local function build_health_payload_context()
  return {
    comms = comms,
    constants = constants,
    master_seen = runtime_ctx.master_seen,
    hb = runtime_config.hb,
    devices = devices,
    registry = registry,
    binding = binding,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    health = health,
    warn_once = warn_once,
    startup_watchdog_tripped = runtime_ctx.startup_watchdog_tripped,
    rt_health = rt_health,
    configured_caps = runtime_config.configured_caps
  }
end

local function master_peer_state()
  return health_payload.master_peer_state(build_health_payload_context())
end

is_master_connected = function()
  return health_payload.is_master_connected(build_health_payload_context())
end

local function build_health_payload()
  return health_payload.build_health_payload(build_health_payload_context())
end

local function add_alarm(sender, severity, message)
  comms:send_alert(severity, message)
end

local function build_status_payload(status_level)
  -- Pass runtime_ctx.capacity_learning into the ctx so update_capacity_learning
  -- reads and updates the PERSISTENT learning state, not an ephemeral copy.
  -- The result is written back to runtime_ctx.capacity_learning so the
  -- capacity_locked check in the AUTONOM/MASTER control loop sees live data.
  local ctx_table = {
    status_level = status_level,
    node_state_machine = node_state_machine,
    current_state = current_state,
    targets = runtime_ctx.targets,
    build_health_payload = build_health_payload,
    status_snapshot = runtime_ctx.status_snapshot,
    devices = devices,
    registry = registry,
    modules = runtime_ctx.modules,
    active_startup = runtime_ctx.active_startup,
    startup_queue = runtime_ctx.startup_queue,
    turbine_adapter = adapters.turbine,
    reactor_adapter = adapters.reactor,
    log_prefix = CONFIG.LOG_PREFIX,
    capacity_learning = runtime_ctx.capacity_learning,  -- persistent state in
    log = log,
  }
  local payload = status_snapshot_lib.build_status_payload(ctx_table)
  -- Write back: update_capacity_learning may have mutated ctx_table.capacity_learning
  local prev_locked = runtime_ctx.capacity_learning
    and runtime_ctx.capacity_learning.locked == true
  runtime_ctx.capacity_learning = ctx_table.capacity_learning
  -- Persist to disk on the first successful lock.
  if not prev_locked and runtime_ctx.capacity_learning
      and runtime_ctx.capacity_learning.locked == true then
    save_capacity_cache(runtime_ctx.capacity_learning)
    log("INFO", string.format(
      "Capacity locked and cached: max_output=%.2f path=%s",
      runtime_ctx.capacity_learning.max_output or 0,
      CONFIG.CAPACITY_CACHE_PATH))
  end
  return payload
end

local function broadcast_status(status_level)
  local payload = build_status_payload(status_level)
  comms:publish_status(payload)
end

local function hello()
  local summary = registry:get_summary()
  local caps = {
    reactors = summary.kinds.reactor and summary.kinds.reactor.bound or 0,
    turbines = summary.kinds.turbine and summary.kinds.turbine.bound or 0
  }
  comms:send_hello(caps)
end

set_reactors_active = function(active, reason)
  return module_lifecycle.set_reactors_active(require_module_lifecycle_context(), active, reason)
end

set_turbines_active = function(active, reason)
  return module_lifecycle.set_turbines_active(require_module_lifecycle_context(), active, reason)
end

apply_safe_controls = function()
  return module_lifecycle.apply_safe_controls(require_module_lifecycle_context())
end

local function scram()
  return module_lifecycle.scram(require_module_lifecycle_context())
end

local REQUIRED_LIFECYCLE_CTX_FUNCTIONS = {
  "get_target_rpm",
  "get_active_startup",
  "set_active_startup",
  "get_turbine_ctrl",
  "setReactorActive",
  "setTurbineActive",
  "setTurbineFlow",
  "applyReactorRods",
  "ensure_reactor_ctrl",
  "update_turbine_flow_state",
  "update_inductor_for_rpm",  -- signature: (name, turbine, caps, rpm, target_rpm)
  "setState",
  "warn_once",
  "warn_unsupported",
  "log",
  "add_alarm"
}

local function validate_module_lifecycle_context(ctx)
  for _, key in ipairs(REQUIRED_LIFECYCLE_CTX_FUNCTIONS) do
    if type(ctx[key]) ~= "function" then
      error("module lifecycle context missing function: " .. tostring(key), 2)
    end
  end
  if type(ctx.constants) ~= "table" then
    error("module lifecycle context missing table: constants", 2)
  end
  if type(ctx.STATE) ~= "table" then
    error("module lifecycle context missing table: STATE", 2)
  end
  if type(ctx.config) ~= "table" then
    error("module lifecycle context missing table: config", 2)
  end
  if type(ctx.modules) ~= "table" then
    error("module lifecycle context missing table: modules", 2)
  end
  if type(ctx.peripherals) ~= "table" then
    error("module lifecycle context missing table: peripherals", 2)
  end
  if type(ctx.binding) ~= "table" then
    error("module lifecycle context missing table: binding", 2)
  end
  return ctx
end

build_module_lifecycle_context = function()
  return {
    constants = constants,
    STATE = STATE,
    config = config,
    peripherals = runtime_ctx.peripherals,
    binding = binding,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    modules = runtime_ctx.modules,
    comms = comms,
    RPM_TOL = CONFIG.RPM_TOLERANCE,
    TURBINE_MODE = TURBINE_CONTROL.mode,
    START_FLOW = CONFIG.START_FLOW,
    log = log,
    warn_once = warn_once,
    warn_unsupported = warn_unsupported,
    get_target_rpm = get_target_rpm,
    get_turbine_ctrl = get_turbine_ctrl,
    get_device_caps = get_device_caps,
    ensure_reactor_ctrl = ensure_reactor_ctrl,
    setTurbineActive = setTurbineActive,
    setReactorActive = setReactorActive,
    setTurbineFlow = setTurbineFlow,
    clamp_turbine_flow = clamp_turbine_flow,
    update_inductor_for_rpm = update_inductor_for_rpm,
    update_turbine_flow_state = update_turbine_flow_state,
    applyReactorRods = applyReactorRods,
    add_alarm = add_alarm,
    ramp_duration = ramp_duration,
    evaluate_reactor_coolant = evaluate_reactor_coolant,
    get_effective_regulator_rod_caps = get_effective_regulator_rod_caps,
    read_current_rods = read_current_rods,
    get_active_startup = function() return runtime_ctx.active_startup end,
    set_active_startup = function(value) runtime_ctx.active_startup = value end,
    get_current_state = function() return current_state end,
    current_state = function() return current_state end,
    setState = setState,
    node_state_machine = node_state_machine
  }
end

require_module_lifecycle_context = function()
  return validate_module_lifecycle_context(build_module_lifecycle_context())
end

local function update_module_limits(module)
  return module_lifecycle.update_module_limits(require_module_lifecycle_context(), module)
end
local function start_module(module_id, module_type, ramp_profile)
  return module_lifecycle.start_module(require_module_lifecycle_context(), module_id, module_type, ramp_profile)
end

local function process_startup()
  module_lifecycle.process_startup(require_module_lifecycle_context())
end

local function update_module_states()
  module_lifecycle.update_module_states(require_module_lifecycle_context())
end

local function monitor_master()
  return state_handlers.monitor_master(build_mode_control_context())
end

local function clamp_autonom_targets()
  return state_handlers.clamp_autonom_targets(build_mode_control_context())
end

local function note_master_seen()
  runtime_ctx.master_seen = os.epoch("utc")
end

local function update_status_snapshot()
  last_status_snapshot = status_snapshot_lib.update_status_snapshot({
    monitor_ui = monitor_ui,
    devices = devices,
    registry = registry,
    comms = comms,
    config = config,
    read_turbine_rpm = read_turbine_rpm,
    read_turbine_flow = read_turbine_flow,
    reactor_adapter = adapters.reactor,
    turbine_adapter = adapters.turbine,
    log_prefix = "RT",
    get_device_caps = get_device_caps,
    get_available_steam = get_available_steam,
    last_status_snapshot = last_status_snapshot
  })
  return last_status_snapshot
end

local function init_monitor()
  local monitor_name_or_err
  runtime_ctx.monitor, monitor_name_or_err = monitor_ui.init(adapters.monitor, config.monitor, config.monitor_scale)
  runtime_ctx.monitor_name = runtime_ctx.monitor and monitor_name_or_err or nil
  if not runtime_ctx.monitor then
    log(CONFIG.LOG_LEVEL.WARN, "Monitor UI disabled: " .. tostring(monitor_name_or_err or "no configured monitor available"))
    -- Fallback: render to the computer's own terminal so the Diagnostics page
    -- (including log mode buttons) is visible on the PC console.
    if term and type(term.current) == "function" then
      runtime_ctx.monitor = term.current()
      runtime_ctx.monitor_name = "term"
      runtime_ctx.monitor_is_term = true
      log(CONFIG.LOG_LEVEL.INFO, "Monitor UI: falling back to local terminal")
    end
  elseif monitor_name_or_err then
    log(CONFIG.LOG_LEVEL.INFO, "Monitor UI initialized on " .. tostring(monitor_name_or_err))
  end
end

local function update_monitor()
  last_status_snapshot = monitor_ui.update(runtime_ctx.monitor, {
    config = config,
    devices = devices,
    registry = registry,
    comms = comms,
    constants = constants,
    master_alerts = runtime_ctx.master_alerts,
    last_command = runtime_ctx.last_command,
    last_command_ts = runtime_ctx.last_command_ts,
    current_state = current_state,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    get_target_rpm = get_target_rpm,
    binding = binding,
    build_health_payload = build_health_payload,
    read_turbine_rpm = read_turbine_rpm,
    read_turbine_flow = read_turbine_flow,
    reactor_adapter = adapters.reactor,
    turbine_adapter = adapters.turbine,
    log_prefix = "RT",
    get_device_caps = get_device_caps,
    get_available_steam = get_available_steam,
    last_status_snapshot = last_status_snapshot
  })
end

local function reset_startup_watchdog()
  runtime_ctx.startup_started_ms = nil
  runtime_ctx.startup_watchdog_tripped = false
end

local function handle_startup_timeout()
  -- R2/R3: Setter übergeben damit startup_diagnostics sauber über die Abstraktion
  -- schreibt. Direkte Mutation von runtime_ctx danach entfernt (war redundant + inkonsistent).
  startup_diagnostics.handle_startup_timeout({
    startup_watchdog_tripped = runtime_ctx.startup_watchdog_tripped,
    startup_started_ms = runtime_ctx.startup_started_ms,
    comms = comms,
    config = config,
    devices = devices,
    registry = registry,
    constants = constants,
    node_state_machine = node_state_machine,
    log = log,
    update_status_snapshot = update_status_snapshot,
    broadcast_status = broadcast_status,
    active_startup = runtime_ctx.active_startup,
    startup_queue = runtime_ctx.startup_queue,
    set_active_startup = function(value) runtime_ctx.active_startup = value end,
    set_startup_queue  = function(value) runtime_ctx.startup_queue = value end
  })
  runtime_ctx.startup_watchdog_tripped = true
  -- active_startup und startup_queue werden jetzt über Setter in startup_diagnostics gesetzt
end
local states

local function build_state_context()
  local ctx = {
    constants = constants,
    STATE = STATE,
    config = config,
    devices = devices,
    modules = runtime_ctx.modules,
    comms = comms,
    targets = runtime_ctx.targets,
    reset_startup_watchdog = reset_startup_watchdog,
    scram = scram,
    get_target_rpm = get_target_rpm,
    start_module = start_module,
    adjust_turbines = adjust_turbines,
    adjust_reactors = adjust_reactors,
    clamp_autonom_targets = clamp_autonom_targets,
    add_alarm = add_alarm,
    handle_startup_timeout = handle_startup_timeout,
    get_startup_started_ms = function() return runtime_ctx.startup_started_ms end,
    set_startup_started_ms = function(value) runtime_ctx.startup_started_ms = value end,
    get_startup_watchdog_tripped = function() return runtime_ctx.startup_watchdog_tripped end,
    set_startup_watchdog_tripped = function(value) runtime_ctx.startup_watchdog_tripped = value end,
    get_startup_queue = function() return runtime_ctx.startup_queue end,
    set_startup_queue = function(value) runtime_ctx.startup_queue = value end,
    get_active_startup = function() return runtime_ctx.active_startup end,
    set_active_startup = function(value) runtime_ctx.active_startup = value end,
    get_network_id = function() return (comms and comms.network and comms.network.id) or config.node_id end,
    get_current_state = function() return current_state end,
    get_node_state_machine = function() return node_state_machine end
  }
  ctx.is_master_connected = is_master_connected
  ctx.monitor_master = function()
    return state_handlers.monitor_master(ctx)
  end
  if type(ctx.is_master_connected) ~= "function" then
    error("rt state context missing required function: is_master_connected", 2)
  end
  if not runtime_ctx.warned.rt_state_context_built then
    runtime_ctx.warned.rt_state_context_built = true
    log("INFO", "State context ready (is_master_connected=true)")
  end
  return ctx
end

local function build_command_context()
  -- NOTE: capacity_learning must be a live getter, not a static snapshot.
  -- runtime_ctx.capacity_learning starts as nil and gets set by build_status_payload.
  -- command_handler.new() captures this ctx once at startup; using a getter
  -- ensures the command handler always sees the current learning state.
  return {
    protocol = protocol,
    constants = constants,
    STATE = STATE,
    TARGET_RPM = CONFIG.TARGET_RPM,
    targets = runtime_ctx.targets,
    node_state_machine = node_state_machine,
    apply_mode = apply_mode,
    request_startup_if_needed = request_startup_if_needed,
    start_module = start_module,
    add_alarm = add_alarm,
    note_master_seen = note_master_seen,
    get_network_id = function() return (comms and comms.network and comms.network.id) or config.node_id end,
    get_current_state = function() return current_state end,
    get_states = function() return states or {} end,
    set_last_command = function(value) runtime_ctx.last_command = value end,
    set_last_command_ts = function(value) runtime_ctx.last_command_ts = value end,
    -- Live getter: capacity_learning is populated after the first status tick.
    get_capacity_learning = function() return runtime_ctx.capacity_learning end,
  }
end
local handle_command

local function send_heartbeat()
  update_status_snapshot()
  comms:send_heartbeat({ state = node_state_machine.state() })
  broadcast_status(constants.status_levels.OK)
  runtime_ctx.last_heartbeat = os.epoch("utc")
end

local function control_tick()
  refresh_module_peripherals()
  process_startup()
  update_module_states()
  updateReactorControl()
  request_startup_if_needed("CONTROL_TICK")
  if current_state == STATE.SAFE and node_state_machine.state() ~= constants.node_states.EMERGENCY then
    node_state_machine:transition(constants.node_states.EMERGENCY)
  end
  node_state_machine:tick()
  update_status_snapshot()
end
local function init()
  log("INFO", "Initializing runtime bootstrap (discover/build/bind/services)")
  dumpPeripherals()
  discover()
  log("INFO", ("Discovery finished: reactors=%d turbines=%d failed=%s"):format(#devices.reactors, #devices.turbines, tostring(devices.discovery_failed)))
  init_turbine_ctrl()
  init_reactor_ctrl()
  set_reactors_active(true, "RT_STARTUP")
  set_turbines_active(true, "RT_STARTUP")
  apply_initial_reactor_rods()
  services = services_lib.manager.new({ log_prefix = "RT" })
  handle_command = command_handler.new(build_command_context())
  comms = services_lib.comms.new({
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
          runtime_ctx.master_alerts = message.payload.alerts
        end
      end
    end
  })
  services:add(comms)
  services:add(services_lib.discovery.new({
    registry = registry,
    discover = discover,
    interval = config.scan_interval,
    managed_registry = false,
    update_health = function(ok)
      devices.discovery_failed = not ok
    end
  }))
  services:add(services_lib.control.new({ tick = control_tick }))
  services:add(services_lib.telemetry.new({
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
  log("INFO", "Service manager initialized")
  states = state_handlers.build(build_state_context())
  node_state_machine = machine.new(states, constants.node_states.OFF)
  log("INFO", "State machine initialized state=" .. tostring(node_state_machine.state()))
  apply_mode(STATE.AUTONOM)
  log("INFO", "Applied initial mode AUTONOM")
  init_monitor()
  hello()
  send_heartbeat()
  log("INFO", "Node ready: " .. comms.network.id)
end

local function is_terminate_error(err)
  local message = tostring(err or ""):lower()
  return message:find("terminate", 1, true) ~= nil
end

local function shutdown(reason)
  local shutdown_reason = tostring(reason or "requested")
  if shutdown_reason:lower():find("terminate", 1, true) then
    log("WARN", "terminate received")
  else
    log("WARN", "shutdown requested: " .. shutdown_reason)
  end
  log("INFO", "shutting down services")
  if services then
    local ok, err = pcall(function() services:stop() end)
    if not ok and not is_terminate_error(err) then
      log("ERROR", "service shutdown error: " .. tostring(err))
    end
  end
  log("INFO", "shutdown complete")
end

local function main_loop()
  log("INFO", "Entering event loop")
  -- Separate monitor timer so UI updates run even when CONTROL tick is
  -- retrying (5s retry delay would freeze the display otherwise).
  local monitor_timer = os.startTimer(0.5)
  while true do
  local timer = os.startTimer(CONFIG.RECEIVE_TIMEOUT)
  while true do
    local event = { os.pullEventRaw() }
    if event[1] == "terminate" then
      return "terminate received"
    end
    if event[1] == "modem_message" then
      comms:handle_event(event)
    elseif event[1] == "timer" and event[2] == timer then
      break
    elseif event[1] == "timer" and event[2] == monitor_timer then
      -- Independent monitor refresh: runs ~every 0.5s regardless of CONTROL state
      update_monitor()
      monitor_timer = os.startTimer(0.5)
    elseif event[1] == "monitor_touch" or event[1] == "mouse_click" or event[1] == "key" then
      monitor_ui.handle_input(event)
    end
  end
  if os.epoch("utc") - runtime_ctx.last_heartbeat > runtime_config.hb * 1000 then
    send_heartbeat()
  end
  services:tick()
end
end

local ok, result_or_err = xpcall(function()
  init()
  return main_loop()
end, function(err)
  return err
end)

if ok then
  shutdown(result_or_err)
else
  if is_terminate_error(result_or_err) then
    shutdown("terminate received")
  else
    shutdown("runtime error: " .. tostring(result_or_err))
    error(result_or_err, 0)
  end
end
