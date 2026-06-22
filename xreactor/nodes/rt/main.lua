-- nodes/rt/main.lua  (RT-Node Rewrite — SCADA-Architektur)
--
-- Orchestrierungsschicht: Boot, Services, Event-Loop.
-- Fachlogik lebt in separaten Modulen:
--   reactor_control.lua   — Steam-Margin-Regler, Rod-Steuerung
--   turbine_control.lua   — Flow, Induktor, Overspeed, Rotation
--   capacity_learning.lua — kontinuierliche Kapazitätsmessung
--   status_snapshot.lua   — Status-Payload für Master
--   monitor_ui.lua        — lokaler Monitor-Renderer
--   command_handler.lua   — REMOTE_UPDATE, SET_SETPOINTS, ...

-- ── Konstanten ───────────────────────────────────────────────────────────────

local CONFIG = {
  LOG_NAME           = "rt",
  LOG_PREFIX         = "RT",
  NODE_ID_PATH       = "/xreactor/config/node_id.txt",
  CONFIG_PATH        = nil,          -- wird von role_descriptor befüllt
  CAPACITY_CACHE_PATH = "/xreactor/config/capacity_cache.lua",
  RECEIVE_TIMEOUT    = 0.5,
  -- Rod-Grenzen
  ROD_MIN            = 0,
  ROD_MAX            = 100,
  INITIAL_ROD_LEVEL  = 100,
  MIN_APPLY_INTERVAL = 0.25,
  -- Turbinen
  TARGET_RPM         = 900,
  COIL_ENGAGE_RPM    = 900,
  COIL_DISENGAGE_RPM = 850,
  MIN_FLOW           = 0,
  MAX_FLOW           = 32000,
  START_FLOW         = 100,
  MIN_ACTIVE_RPM     = 10,
  RPM_TOLERANCE      = 15,
  TURBINE_MODE_RAMP  = "RAMP",
}

-- ── Bootstrap ────────────────────────────────────────────────────────────────

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({ role = "rt" })
local require = bootstrap.require

-- ── Requires ─────────────────────────────────────────────────────────────────

local constants       = require("shared.constants")
local protocol        = require("core.protocol")
local utils           = require("core.utils")
local health          = require("core.health")
local rails           = require("core.control_rails")
local safety          = require("core.safety")
local fluid           = require("core.fluid")
local registry_lib    = require("core.registry")
local service_manager = require("services.service_manager")
local comms_service   = require("services.comms_service")
local telemetry_service = require("services.telemetry_service")
local discovery_service = require("services.discovery_service")
local ui_service      = require("services.ui_service")
local support_runtime = require("nodes.support.runtime")
local role_logic      = require("nodes.support.role_logic")
local binding         = require("nodes.rt.binding")
local config_normalizer = require("nodes.rt.config_normalizer")
local capacity_cache  = require("nodes.rt.capacity_cache")
local monitor_ui      = require("nodes.rt.monitor_ui")
local command_handler_lib = require("nodes.rt.command_handler")
local state_handlers  = require("nodes.rt.state_handlers")
local module_lifecycle = require("nodes.rt.module_lifecycle")
local status_snapshot_lib = require("nodes.rt.status_snapshot")
local startup_diagnostics = require("nodes.rt.startup_diagnostics")
local discovery_runtime   = require("nodes.rt.discovery_runtime")
local health_payload      = require("nodes.rt.health_payload")
local flow_apply_helpers  = require("nodes.rt.flow_apply_helpers")
local reactor_steam_guard = require("nodes.rt.reactor_steam_guard")
local turbine_regulator   = require("core.turbine_regulator")
local machine             = require("core.state_machine")

-- Neue Fachmodule
local reactor_control   = require("nodes.rt.reactor_control")
local turbine_control   = require("nodes.rt.turbine_control")
local capacity_learning = require("nodes.rt.capacity_learning")

local adapters = {
  reactor = require("adapters.reactor"),
  turbine  = require("adapters.turbine"),
  monitor  = require("adapters.monitor"),
}
local rt_default_config = require("nodes.rt.config")

-- ── Config ───────────────────────────────────────────────────────────────────

CONFIG.CONFIG_PATH = "/xreactor/config/rt.lua"
local DEFAULT_CONFIG = utils.deep_copy(rt_default_config)
local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}
local function add_config_warning(msg) table.insert(config_warnings, msg) end
config_normalizer.migrate_legacy_paths(config, add_config_warning)
config_normalizer.validate_config(config, DEFAULT_CONFIG, add_config_warning, utils)
config_normalizer.apply_runtime_defaults(config, DEFAULT_CONFIG, {
  target_rpm = CONFIG.TARGET_RPM, min_flow = CONFIG.MIN_FLOW,
  max_flow = CONFIG.MAX_FLOW, flow_step = 50, rod_tick = 1,
  deep_copy = utils.deep_copy,
  normalize_rails = function(v, d)
    return config_normalizer.normalize_rails(v, d, utils, safety,
      CONFIG.MIN_FLOW, CONFIG.MAX_FLOW)
  end
})

local node_id = support_runtime.init_logging({
  utils = utils, config = config,
  runtime_config = CONFIG, config_meta = config_meta,
  config_warnings = config_warnings
})

-- ── Zentraler Mutable State ───────────────────────────────────────────────────
-- Alles was sich zur Laufzeit ändert, bündelt sich hier — explizit, kein
-- globaler Zugriff. Wird als ctx an alle Fachmodule weitergegeben.

local state = {
  -- Reaktor-Regelung
  last_applied_rods       = nil,
  last_rod_apply_ts       = 0,
  last_rod_change_ts      = 0,
  last_rod_direction      = nil,
  last_reactor_demand     = 0,
  steam_tank_name         = nil,
  reactor_rails_state     = rails.new_state(),
  reactor_steam_guard_state = {},
}
local ctx  -- wird in init() vollständig befüllt

-- Weitere State-Objekte
local runtime_config = {
  configured_reactors = utils.deep_copy(config.reactors or {}),
  configured_turbines = utils.deep_copy(config.turbines or {}),
}
runtime_config.configured_caps = {
  reactors = #runtime_config.configured_reactors,
  turbines  = #runtime_config.configured_turbines,
}

local registry = registry_lib.new({
  node_id = node_id, role = "rt", log_prefix = CONFIG.LOG_PREFIX
})
local rt_health = health.new({})
local devices = {
  reactors = {}, turbines = {}, adapters = { reactors = {}, turbines = {} },
  discovery_failed = false, registry_summary = nil,
  registry_load_error = nil, proto_mismatch = false,
  binding_signature = nil, last_scan_ts = nil, discovery_log_signature = nil
}
local master_seen_ts = nil
local master_alerts  = {}

local comms, services
local node_state_machine
local current_state_value = "INIT"
local states_table

local STATE = {
  INIT   = "INIT", AUTONOM = "AUTONOM",
  MASTER = "MASTER", SAFE = "SAFE"
}

local warned = {}
local last_command, last_command_ts
local last_status_snapshot
local capacity_learning_state  -- persistenter Learning-State

-- ── Hilfsfunktionen ──────────────────────────────────────────────────────────

local function log(level, msg)
  utils.log(CONFIG.LOG_PREFIX, msg, level)
end

local warn_once
warn_once = function(key, msg)
  if warned[key] then return end
  warned[key] = true
  log("WARN", msg)
end

local safe_wrapped_call = support_runtime.safe_wrapped_call

local function current_state() return current_state_value end

local function is_master_connected()
  return role_logic.is_master_connected({
    comms = comms, master_role = constants.roles.MASTER,
    last_seen_ts = master_seen_ts,
    heartbeat_interval = config.heartbeat_interval
  })
end

local function master_peer_state()
  return role_logic.master_peer_state(comms, constants.roles.MASTER)
end

-- ── Capacity Cache ───────────────────────────────────────────────────────────

local function load_capacity_cache()
  return capacity_cache.load({
    path = CONFIG.CAPACITY_CACHE_PATH,
    turbine_count = #(config.turbines or {}),
    log = log
  })
end

local function save_capacity_cache(learning)
  capacity_cache.save(learning, {
    path = CONFIG.CAPACITY_CACHE_PATH,
    turbine_count = #(config.turbines or {})
  })
end

-- ── ctx-Builder ───────────────────────────────────────────────────────────────
-- Baut das ctx-Objekt, das alle Fachmodule bekommen.
-- Statt vieler lokaler Closures hat jede Funktion jetzt eine explizite
-- Abhängigkeitsliste am Kopf (ctx.*).

local function build_ctx()
  return {
    -- State-Felder (direkt, nicht geschachtelt)
    last_applied_rods         = state.last_applied_rods,
    last_rod_apply_ts         = state.last_rod_apply_ts,
    last_rod_change_ts        = state.last_rod_change_ts,
    last_rod_direction        = state.last_rod_direction,
    last_reactor_demand       = state.last_reactor_demand,
    steam_tank_name           = state.steam_tank_name,
    reactor_rails_state       = state.reactor_rails_state,
    reactor_steam_guard_state = state.reactor_steam_guard_state,
    -- Runtime-State (von runtime_ctx)
    peripherals               = devices,
    reactor_ctrl              = {},   -- wird in init_reactor_ctrl befüllt
    turbine_ctrl_store        = {},   -- wird in init_turbine_ctrl befüllt
    autonom_state             = {
      reactors = {}, turbines = {},
      pending_rod_direction = nil,
      partial_turbine_index = 1,
      partial_turbine_last_rotate = 0,
    },
    autonom_control_logged    = false,
    capability_cache          = { reactors = {}, turbines = {} },
    last_reactor_tick         = 0,
    last_reactor_debug_log    = 0,
    capacity_learning         = nil,
    -- Config
    config  = config,
    CONFIG  = CONFIG,
    -- Module
    adapters          = adapters,
    safety            = safety,
    rails             = rails,
    fluid             = fluid,
    utils             = utils,
    reactor_steam_guard = reactor_steam_guard,
    turbine_regulator = turbine_regulator,
    flow_apply_helpers = flow_apply_helpers,
    binding           = binding,
    runtime_config    = runtime_config,
    -- Zugriff auf andere Fachmodule
    reactor_control   = reactor_control,
    -- Zustands-Accessoren
    targets           = nil,  -- wird in init() gesetzt
    current_state     = current_state,
    STATE             = STATE,
    -- Funktionen
    log               = log,
    warn_once         = warn_once,
    safe_wrapped_call = safe_wrapped_call,
    load_capacity_cache = load_capacity_cache,
    get_turbine_ctrl  = function(name)
      return turbine_control.get_turbine_ctrl(ctx, name)
    end,
  }
end

-- ── State-Writeback ───────────────────────────────────────────────────────────
-- ctx ist keine Live-Referenz auf state — nach jedem Tick schreiben wir
-- die mutierten Felder zurück.

local function writeback_ctx()
  state.last_applied_rods         = ctx.last_applied_rods
  state.last_rod_apply_ts         = ctx.last_rod_apply_ts
  state.last_rod_change_ts        = ctx.last_rod_change_ts
  state.last_rod_direction        = ctx.last_rod_direction
  state.last_reactor_demand       = ctx.last_reactor_demand
  state.steam_tank_name           = ctx.steam_tank_name
  state.reactor_rails_state       = ctx.reactor_rails_state
  state.reactor_steam_guard_state = ctx.reactor_steam_guard_state

  -- Capacity-Learning zurückschreiben
  if ctx.capacity_learning and ctx.capacity_learning.ready == true then
    local prev_max = capacity_learning_state
      and capacity_learning_state.max_output or 0
    if ctx.capacity_learning.max_output > prev_max then
      save_capacity_cache(ctx.capacity_learning)
      log("INFO", string.format("Capacity cached: max_output=%.2f",
        ctx.capacity_learning.max_output))
    end
    capacity_learning_state = ctx.capacity_learning
  end
end

-- ── Discovery ────────────────────────────────────────────────────────────────

local function build_discovery_context()
  return {
    config = config,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    peripherals = devices,
    utils = utils,
    capability_cache = ctx and ctx.capability_cache or {},
    build_capabilities = function(name)
      return turbine_control.get_device_caps(ctx, "turbines", name)
    end,
    log = log, log_prefix = CONFIG.LOG_PREFIX,
    binding = binding,
    reactor_adapter = adapters.reactor,
    turbine_adapter = adapters.turbine,
    discovery_log = require("nodes.rt.discovery_log"),
    devices = devices,
    registry = registry,
    monitor_name = nil,
    build_modules = function() end,
    refresh_module_peripherals = function() end,
  }
end

local function discover()
  discovery_runtime.discover(build_discovery_context())
  devices.last_scan_ts = os.epoch("utc")
end

-- ── Status-Payload ───────────────────────────────────────────────────────────

local function build_status_payload(status_level)
  local ctx_snap = {
    status_level         = status_level or constants.status_levels.OK,
    node_state_machine   = node_state_machine,
    current_state        = current_state_value,
    targets              = ctx.targets,
    build_health_payload = function()
      return health_payload.build_health_payload({
        comms = comms, constants = constants,
        master_seen = master_seen_ts or os.epoch("utc"),
        hb = config.heartbeat_interval,
        devices = devices, registry = registry, binding = binding,
        configured_reactors = runtime_config.configured_reactors,
        configured_turbines = runtime_config.configured_turbines,
        health = rt_health, warn_once = warn_once,
        startup_watchdog_tripped = false,
        rt_health = rt_health,
        configured_caps = runtime_config.configured_caps,
      })
    end,
    devices              = devices,
    registry             = registry,
    modules              = {},
    active_startup       = nil,
    startup_queue        = {},
    turbine_adapter      = adapters.turbine,
    reactor_adapter      = adapters.reactor,
    log_prefix           = CONFIG.LOG_PREFIX,
    capacity_learning    = ctx and ctx.capacity_learning or capacity_learning_state,
    log                  = log,
  }
  local payload = status_snapshot_lib.build_status_payload(ctx_snap)
  -- Learning-State zurückschreiben
  if ctx then ctx.capacity_learning = ctx_snap.capacity_learning end
  writeback_ctx()
  return payload
end

-- ── Monitor ───────────────────────────────────────────────────────────────────

local function update_monitor()
  local mon = devices.monitor
  if not mon then return end
  last_status_snapshot = monitor_ui.update(mon, {
    config = config, devices = devices, registry = registry,
    comms = comms, constants = constants,
    master_alerts = master_alerts,
    last_command = last_command, last_command_ts = last_command_ts,
    current_state = current_state_value,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    get_target_rpm = function() return reactor_control.get_target_rpm and
      ctx.CONFIG.TARGET_RPM or CONFIG.TARGET_RPM end,
    binding = binding,
    build_health_payload = function() return build_status_payload() end,
    read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
    read_turbine_flow = function(t, c) return turbine_control.read_turbine_flow(ctx, t, c) end,
    reactor_adapter = adapters.reactor,
    turbine_adapter = adapters.turbine,
    log_prefix = CONFIG.LOG_PREFIX,
    get_device_caps = function(k, n) return turbine_control.get_device_caps(ctx, k, n) end,
    get_available_steam = function() return reactor_control.get_available_steam(ctx) end,
    last_status_snapshot = last_status_snapshot,
    capacity_learning = ctx and ctx.capacity_learning or capacity_learning_state,
  })
end

-- ── Control-Tick ──────────────────────────────────────────────────────────────

local function control_tick()
  -- Reaktor-Regelung
  reactor_control.updateReactorControl(ctx)
  -- Turbinen-Regelung
  turbine_control.updateControl(ctx)
  -- Learning-Update (als Teil des Status-Snapshots, läuft via build_status_payload)
  writeback_ctx()
end

-- ── Command-Handler ───────────────────────────────────────────────────────────

local handle_command

local function build_command_ctx()
  return {
    protocol = protocol, constants = constants, STATE = STATE,
    TARGET_RPM = CONFIG.TARGET_RPM,
    targets = ctx and ctx.targets or {},
    node_state_machine = node_state_machine,
    apply_mode = function(mode)
      state_handlers.apply_mode({
        STATE = STATE, config = config, log = log,
        is_master_connected = is_master_connected,
        get_current_state = current_state,
        set_current_state = function(v) current_state_value = v end,
        get_node_state_machine = function() return node_state_machine end,
      }, mode)
    end,
    request_startup_if_needed = function() end,
    start_module = function() end,
    add_alarm = function(_, severity, msg) comms:send_alert(severity, msg) end,
    note_master_seen = function() master_seen_ts = os.epoch("utc") end,
    get_network_id = function()
      return comms and comms.network and comms.network.id or config.node_id
    end,
    get_current_state = current_state,
    get_states = function() return states_table or {} end,
    set_last_command    = function(v) last_command = v end,
    set_last_command_ts = function(v) last_command_ts = v end,
    get_capacity_learning = function()
      return ctx and ctx.capacity_learning or capacity_learning_state
    end,
  }
end

-- ── Init ─────────────────────────────────────────────────────────────────────

local function init()
  log("INFO", "RT-Node starting (SCADA rewrite)")

  -- ctx aufbauen
  ctx = build_ctx()
  ctx.targets = {
    power = 0, steam = 0, rpm = CONFIG.TARGET_RPM,
    enable_reactors = true, enable_turbines = true
  }

  -- Hardware-Discovery
  discover()
  log("INFO", string.format("Discovery: reactors=%d turbines=%d",
    #devices.reactors, #devices.turbines))

  -- Reaktor/Turbinen-State initialisieren
  reactor_control.init_reactor_ctrl(ctx)
  turbine_control.init_turbine_ctrl(ctx)

  -- Capacity-Cache laden
  local cached = load_capacity_cache()
  if cached then
    ctx.capacity_learning = cached
    capacity_learning_state = cached
    log("INFO", string.format("Capacity loaded from cache: max_output=%.2f",
      cached.max_output))
  end

  -- Initiale Rod-Stellung
  reactor_control.apply_initial_reactor_rods(ctx)

  -- Services
  services = service_manager.new({ log_prefix = "RT" })

  handle_command = command_handler_lib.new(build_command_ctx())

  comms = comms_service.new({
    config = config, log_prefix = "RT",
    on_command = handle_command,
    on_message = function(message)
      if message.type == constants.message_types.ERROR
          and message.payload and message.payload.code == "PROTO_MISMATCH" then
        devices.proto_mismatch = true; return
      end
      if message.role == constants.roles.MASTER then
        master_seen_ts = os.epoch("utc")
        if message.type == constants.message_types.STATUS
            and message.payload and message.payload.alerts then
          master_alerts = message.payload.alerts
        end
      end
    end
  })
  services:add(comms)

  services:add(discovery_service.new({
    registry = registry,
    discover = discover,
    interval = config.scan_interval or config.heartbeat_interval,
    managed_registry = false,
    update_health = function(ok) devices.discovery_failed = not ok end,
  }))

  -- Control-Service: läuft auf eigenem Intervall (nicht am Comms-Timeout gebunden)
  services:add({
    name = "control",
    tick = function() control_tick() end,
  })

  services:add(telemetry_service.new({
    comms = comms,
    status_interval  = config.status_interval or config.heartbeat_interval,
    heartbeat_interval = config.heartbeat_interval,
    heartbeat_state  = function()
      return { state = node_state_machine and node_state_machine.state() or "INIT" }
    end,
    build_payload = function()
      return build_status_payload(constants.status_levels.OK)
    end,
  }))

  services:add(ui_service.new({
    interval = 0.5,
    render   = update_monitor,
    handle_input = function(event) monitor_ui.handle_input(event) end,
  }))

  services:init()

  -- State Machine
  local state_ctx = {
    STATE = STATE, config = config, log = log,
    is_master_connected = is_master_connected,
    get_current_state = current_state,
    set_current_state = function(v) current_state_value = v end,
    get_node_state_machine = function() return node_state_machine end,
    adjust_turbines = function() turbine_control.updateControl(ctx) end,
    adjust_reactors = function() reactor_control.updateReactorControl(ctx) end,
  }
  states_table = state_handlers.build(state_ctx)
  node_state_machine = machine.new(states_table, constants.node_states.OFF)

  -- Initiale Mode: AUTONOM
  current_state_value = STATE.AUTONOM
  node_state_machine:transition(constants.node_states.RUNNING)

  -- Monitor initialisieren
  local mon_entry = adapters.monitor.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  devices.monitor = mon_entry and mon_entry.mon or nil
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current()
  end
  monitor_ui.init(devices.monitor, config.monitor, config.monitor_scale)

  -- Hello + erster Heartbeat
  comms:send_hello({
    reactors = #devices.reactors,
    turbines  = #devices.turbines,
  })
  build_status_payload(constants.status_levels.OK)

  log("INFO", "RT-Node ready: " .. (comms.network and comms.network.id or node_id))
end

-- ── Start ────────────────────────────────────────────────────────────────────

init()
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms)
