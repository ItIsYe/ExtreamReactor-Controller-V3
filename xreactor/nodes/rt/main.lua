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
  -- Fix (2026-07-14): CRITICAL. RT-P0 (siehe docs/CODING_AI_RT_CONTROL_
  -- CADENCE_2026-07-12.md). 0.5s hiess: der periodische Scheduler-Zweig
  -- von support_runtime.run_event_loop() (der Reaktor-/Turbinen-Control-
  -- Tick ausloest, siehe services:add({name="control", ...}) unten) lief
  -- nur alle 0.5s (2 Hz) -- weit unter der verbindlichen 10-Hz-Vorgabe
  -- (reactor_control_interval_s = turbine_control_interval_s = 0.10).
  -- 0.1s bringt den gesamten Scheduler-Zyklus auf die geforderten 10 Hz.
  -- Andere periodische Services (Discovery/Telemetry/UI) sind bereits
  -- ueber ihre eigene interval-/due-Pruefung von dieser Aenderung
  -- entkoppelt und behalten ihre konfigurierte Rate.
  RECEIVE_TIMEOUT    = 0.1,
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
local startup_diagnostics = require("nodes.rt.startup_diagnostics")
local status_snapshot_lib = require("nodes.rt.status_snapshot")
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
local reactor_names = utils.load_config("/xreactor/config/reactor_names.lua", {
  version = 2, completed = false, aliases = {}, reactors = {},
})
if type(reactor_names) ~= "table" or reactor_names.completed ~= true
    or type(reactor_names.aliases) ~= "table" then
  reactor_names = { aliases = {} }
end
local config_warnings = {}
local function add_config_warning(msg) table.insert(config_warnings, msg) end
config_normalizer.migrate_legacy_paths(config, add_config_warning)
-- Fix (2026-07-16): CRITICAL (RT-P1, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 5). Migriert bekannte historische
-- Default-Werte (autonom.reactor_adjust_interval=5.0/reactor_adjust_
-- interval_individual=1.0, vor dem 10-Hz-Fix) gezielt auf die neuen 0.10-
-- Defaults, gesteuert ueber config.version -- laeuft NUR, wenn config.
-- version noch unter dem Migrations-Stand liegt, und wird SOFORT
-- persistiert, damit sie garantiert nur einmal ausgefuehrt wird (nicht bei
-- jedem Boot erneut, siehe migrate_schema_version()-Kommentar in
-- config_normalizer.lua fuer die genaue Begruendung).
if config_normalizer.migrate_schema_version(config, DEFAULT_CONFIG, add_config_warning) then
  pcall(utils.write_config, CONFIG.CONFIG_PATH, config)
end
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
  node_id = node_id, role = "rt", log_prefix = CONFIG.LOG_PREFIX,
  aliases = reactor_names.aliases,
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

-- Fix (2026-07-13): RT-P1.4 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md). manifest_id/release_id wurden bisher bei
-- JEDEM Aufruf der Status-Snapshot-Funktion (Monitor-Hotpath, laeuft
-- periodisch) per require()/dofile() neu eingelesen -- unnoetiger
-- Datei-I/O in einem Pfad, der so oft wie moeglich schlank bleiben soll.
-- Einmalig beim Modul-Laden berechnet, danach nur noch referenziert.
local RT_BUILD_INFO = (function()
  local ok, rel = pcall(require, "xreactor.release")
  if not ok or type(rel) ~= "table" then
    ok, rel = pcall(dofile, "/xreactor/release.lua")
  end
  if type(rel) == "table" then
    return { manifest_id = rel.manifest_id or "unknown", release_id = rel.release_id or "unknown" }
  end
  return { manifest_id = "unknown", release_id = "unknown" }
end)()

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

-- Fix (2026-07-16): CRITICAL (MASTER-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md). Modul-Startup-Zustand (welches Modul gerade
-- hochfaehrt, die Warteschlange, der Watchdog) war bisher NUR als lokale
-- No-Op-Stubs vorhanden ("RT-Node hat keine Modul-Startup-Sequenz") -- echte,
-- persistente Zustandsvariablen hier, damit start_module()/process_startup()/
-- request_startup_if_needed() etc. tatsaechlich funktionieren koennen.
local modules_registry = {}
local active_startup_id = nil
local startup_queue_list = {}
local startup_started_ms_value = nil
local startup_watchdog_tripped_value = false
-- Forward-Deklaration nach demselben Muster wie "local ctx" oben: make_
-- lifecycle_ctx() wird erst in init() definiert (braucht comms/ctx/node_
-- state_machine als Upvalues), muss aber auch von build_command_ctx() (VOR
-- init() definiert) aus erreichbar sein.
local make_lifecycle_ctx

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
  local topology = {}
  for _, name in ipairs(config.turbines or {}) do
    topology[#topology + 1] = { name = name }
  end
  return capacity_cache.load({
    path = CONFIG.CAPACITY_CACHE_PATH,
    turbine_count = #(config.turbines or {}),
    topology_signature = capacity_learning.topology_signature(topology),
    log = log
  })
end

local function save_capacity_cache(learning)
  return capacity_cache.save(learning, {
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
    warned            = {},   -- Dedup-Map für warn_once
    -- Fix (2026-07-13): CRITICAL (RT-P0.2, siehe docs/CODING_AI_OTHER_
    -- NODES_PERFORMANCE_2026-07-12.md). reactor_control.lua's SAFE-
    -- Recovery-Pfad (updateReactorControl(), beim Abkuehlen aller
    -- Reaktoren unter die Recovery-Schwelle) ruft ctx.setState(ctx.
    -- STATE.MASTER, "SAFETY_TEMPERATURE_RECOVERED") auf -- dieser
    -- Context (build_ctx()'s Ergebnis, tatsaechlich fuer updateReactor
    -- Control() verwendet) hatte bisher UEBERHAUPT kein setState-Feld,
    -- nicht einmal node_state_machine selbst. Sobald alle Reaktoren aus
    -- SAFE ausreichend abgekuehlt waren, schlug der Control-Service mit
    -- "attempt to call a nil value" fehl und ging in Service-Backoff --
    -- ausgerechnet im sicherheitskritischsten Moment (Recovery aus einem
    -- Notzustand). node_state_machine ist eine Modul-Ebene-Variable
    -- (siehe "local node_state_machine" oben) -- wird hier als Upvalue
    -- referenziert; Lua-Closures greifen bei jedem Aufruf auf den
    -- AKTUELLEN Wert zu, nicht auf den zum Zeitpunkt der Funktions-
    -- erstellung, daher ist es unproblematisch, dass node_state_machine
    -- erst NACH build_ctx()'s Aufruf tatsaechlich zugewiesen wird (siehe
    -- "node_state_machine = machine.new(...)" weiter unten) -- setState
    -- wird sowieso erst viel spaeter, waehrend des normalen Regelbetriebs,
    -- tatsaechlich aufgerufen. Nutzt die bereits im gesamten RT-Code
    -- etablierte transition(target)-API (siehe z.B. command_handler.lua/
    -- module_lifecycle.lua) statt ein neues, inkonsistentes Muster
    -- einzufuehren -- der "reason"-Parameter wird zwar nicht an
    -- transition() weitergereicht (kein anderer Aufrufer im Projekt
    -- nutzt einen Context-Parameter dafuer), aber wie vom Dokument
    -- gefordert trotzdem geloggt.
    setState = function(next_state, reason)
      log("INFO", "State-Uebergang: " .. tostring(next_state) .. (reason and (" (" .. tostring(reason) .. ")") or ""))
      if node_state_machine then
        node_state_machine:transition(next_state)
      else
        warn_once("setState_no_machine", "setState aufgerufen bevor node_state_machine bereit war")
      end
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
    local topology_changed = not capacity_learning_state
      or ctx.capacity_learning.topology_signature ~= capacity_learning_state.topology_signature
    if ctx.capacity_learning.dirty == true
        or topology_changed
        or ctx.capacity_learning.max_output > prev_max then
      local saved, save_err = save_capacity_cache(ctx.capacity_learning)
      if saved then
        ctx.capacity_learning.dirty = false
        log("INFO", string.format("Capacity cached: max_output=%.2f",
          ctx.capacity_learning.max_output))
      else
        log("WARN", "Capacity cache write failed: " .. tostring(save_err))
      end
    end
    capacity_learning_state = ctx.capacity_learning
  elseif ctx.capacity_learning then
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
    -- Fix (2026-07-16): CRITICAL (MASTER-P0, siehe docs/CODING_AI_OTHER_NODES_
    -- PERFORMANCE_2026-07-12.md). Waren bisher No-Ops -- das Modul-Register
    -- (modules_registry) wurde dadurch NIE befuellt, wodurch start_module()/
    -- process_startup() immer auf ein leeres ctx.modules trafen. M.refresh_
    -- bindings() ruft beide Funktionen ohne Argumente und ohne Auswertung
    -- des Rueckgabewerts auf (ctx.build_modules(); ctx.refresh_module_
    -- peripherals()) -- die shared modules_registry-Tabelle muss deshalb IN
    -- PLACE mutiert werden, nicht per Rueckgabewert ersetzt werden.
    build_modules = function()
      local fresh = discovery_runtime.build_modules(devices)
      for id in pairs(modules_registry) do
        if not fresh[id] then
          modules_registry[id] = nil
        end
      end
      for id, entry in pairs(fresh) do
        if not modules_registry[id] then
          modules_registry[id] = entry
        end
      end
    end,
    refresh_module_peripherals = function()
      discovery_runtime.refresh_module_peripherals(modules_registry, devices, function(kind, name)
        return turbine_control.get_device_caps(ctx, kind, name)
      end)
    end,
  }
end

local function discover()
  discovery_runtime.discover(build_discovery_context())
  devices.last_scan_ts = os.epoch("utc")
end

-- Fix (2026-07-15): RT-P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md Abschnitt 6, "stabilen Discovery-Default nach erfolgreichem
-- Boot verlangsamen"). discover() lief bisher fest alle config.scan_interval
-- (10s), fuer immer, unabhaengig davon ob sich die gebundenen Geraete seit
-- Ewigkeiten nicht mehr geaendert haben -- jeder Lauf scannt peripheral.
-- getNames() plus getMethods()/getType()/adapter.inspect() fuer jedes
-- sichtbare Geraet. Nutzt den bestehenden should_discover-Erweiterungspunkt
-- von services/discovery_service.lua (KEINE Aenderung am geteilten Service
-- noetig, der auch von WATER/FUEL/etc. genutzt wird): nach
-- DISCOVERY_STABLE_STREAK unveraenderten Scans in Folge (binding_signature
-- bleibt gleich) wird nur noch alle DISCOVERY_SLOW_MULTIPLIER * scan_interval
-- Sekunden tatsaechlich gescannt -- eine echte Aenderung (Attach/Detach)
-- wird beim naechsten faelligen Scan erkannt und setzt sofort wieder auf
-- die normale 10s-Kadenz zurueck.
--
-- Fix (2026-07-16): CRITICAL (RT-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 4). discovery_service.lua's tick()
-- aktualisiert self.last_scan NUR bei einem tatsaechlich ausgefuehrten Scan
-- (Zeile "if not should_scan then return end" laeuft VOR "self.last_scan =
-- ts"). Ein uebersprungener faelliger Scan veraendert last_scan also NICHT
-- -- "due" (ts - last_scan >= interval*1000) bleibt ab diesem Zeitpunkt bei
-- JEDEM folgenden RT-Schedulertick (~alle 0.1s) wahr. Der alte Zaehler
-- (discovery_slow_skip_count += 1 pro should_discover()-Aufruf) zaehlte
-- deshalb Scheduler-TICKS, nicht echte 10s-Scanintervalle -- erreichte
-- DISCOVERY_SLOW_MULTIPLIER=6 schon nach ~0.6s statt nach den beabsichtigten
-- ~60s. Jetzt: eine echte Wanduhr-Deadline (discovery_next_slow_scan_at,
-- naechster ZULAESSIGER Scan-Zeitpunkt in ms) statt eines Aufruf-Zaehlers --
-- should_discover() bekommt den Discovery-Service selbst als ersten
-- Parameter (service.interval fuer die tatsaechlich konfigurierte
-- Basis-Rate) und vergleicht direkt gegen die aktuelle Zeit. Ein weit in
-- der Zukunft liegender naechster Scan wird bei Erreichen GENAU EINMAL
-- ausgefuehrt und die Deadline von diesem Zeitpunkt aus neu gesetzt (kein
-- Scanburst durch mehrere "verpasste" Zwischenschritte).
local DISCOVERY_STABLE_STREAK    = 3
local DISCOVERY_SLOW_MULTIPLIER  = 6
local discovery_stable_count = 0
local discovery_next_slow_scan_at = 0

local function should_discover(service, ts, _event, due)
  if not due then return false end
  if discovery_stable_count < DISCOVERY_STABLE_STREAK then
    return true
  end
  local interval_ms = (tonumber(service and service.interval) or 10) * 1000
  local slow_period_ms = DISCOVERY_SLOW_MULTIPLIER * interval_ms
  if discovery_next_slow_scan_at == 0 or ts >= discovery_next_slow_scan_at then
    discovery_next_slow_scan_at = ts + slow_period_ms
    return true
  end
  return false
end

local function discover_with_stability_tracking()
  local signature_before = devices.binding_signature
  discover()
  if devices.binding_signature == signature_before then
    discovery_stable_count = discovery_stable_count + 1
  else
    discovery_stable_count = 0
    discovery_next_slow_scan_at = 0
  end
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
        health = health, warn_once = warn_once,
        -- Fix (2026-07-16): CRITICAL (MASTER-P0, siehe docs/CODING_AI_OTHER_
        -- NODES_PERFORMANCE_2026-07-12.md). War hart auf false verdrahtet --
        -- MASTER konnte den vom Pflicht-Test geforderten degradierten
        -- Zustand nach einem Startup-Watchdog-Timeout dadurch NIE ueber die
        -- normale Health-Telemetrie sehen (CONTROL_DEGRADED-Reason blieb
        -- immer unerreichbar).
        startup_watchdog_tripped = startup_watchdog_tripped_value,
        rt_health = rt_health,
        configured_caps = runtime_config.configured_caps,
      })
    end,
    devices              = devices,
    registry             = registry,
    -- Fix (2026-07-16): CRITICAL (MASTER-P0). modules/active_startup/
    -- startup_queue waren hart auf {}/nil/{} verdrahtet -- MASTER erhielt
    -- dadurch NIE echten Modul-Fortschritt (ramp_state, STARTING/STABLE
    -- etc.) per Telemetrie und konnte "erst nach passender Stable-
    -- Telemetrie zum naechsten Modul wechseln" (Pflicht-Fix) gar nicht
    -- erfuellen.
    modules              = modules_registry,
    active_startup       = active_startup_id,
    startup_queue        = startup_queue_list,
    turbine_adapter      = adapters.turbine,
    reactor_adapter      = adapters.reactor,
    log_prefix           = CONFIG.LOG_PREFIX,
    capacity_learning    = ctx and ctx.capacity_learning or capacity_learning_state,
    log                  = log,
    config               = config,
    -- Felder für status_snapshot.build_turbine_snapshots / build_reactor_snapshots
    get_available_steam  = function() return reactor_control.get_available_steam(ctx) end,
    get_device_caps      = function(k,n) return turbine_control.get_device_caps(ctx,k,n) end,
    read_turbine_rpm     = function(t,c) return turbine_control.read_turbine_rpm(ctx,t,c) end,
    read_turbine_flow    = function(t,c) return turbine_control.read_turbine_flow(ctx,t,c) end,
    last_status_snapshot = last_status_snapshot,
    monitor_ui           = monitor_ui,
    status_snapshot      = status_snapshot_lib,
  }
  local payload = status_snapshot_lib.build_status_payload(ctx_snap)
  -- Learning-State zurückschreiben
  if ctx then ctx.capacity_learning = ctx_snap.capacity_learning end
  writeback_ctx()
  return payload
end

-- Fix (2026-07-16): CRITICAL (MASTER-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md). startup_diagnostics.M.handle_startup_timeout()
-- braucht einen Temperatur-/RPM-Schnappschuss (ctx.update_status_snapshot()
-- -> {max_temp, avg_rpm, turbines={...}}), um zu entscheiden ob der
-- Startup-Watchdog-Timeout ein EMERGENCY (zu heiss/zu schnell) oder nur ein
-- WARNING (schlicht zu langsam) ist. status_snapshot.build_status_payload()
-- liefert kein max_temp/avg_rpm, daher ein eigener, direkter Scan ueber die
-- gebundenen Peripheriegeraete (dieselben Adapter wie build_turbine_
-- snapshots/build_reactor_snapshots in status_snapshot.lua).
local function update_status_snapshot()
  local max_temp = nil
  for _, entry in ipairs(registry:get_bound_devices("reactor")) do
    local info = adapters.reactor.inspect(entry.name, CONFIG.LOG_PREFIX)
    local temp = info and info.temperature
    if type(temp) == "number" and (not max_temp or temp > max_temp) then
      max_temp = temp
    end
  end
  local turbines = {}
  local rpm_sum, rpm_count = 0, 0
  for _, entry in ipairs(registry:get_bound_devices("turbine")) do
    local info = adapters.turbine.inspect(entry.name, CONFIG.LOG_PREFIX)
    local rpm = info and info.rpm
    if type(rpm) == "number" then
      rpm_sum = rpm_sum + rpm
      rpm_count = rpm_count + 1
    end
    table.insert(turbines, { name = entry.name, rpm = rpm })
  end
  return {
    max_temp = max_temp,
    avg_rpm  = rpm_count > 0 and (rpm_sum / rpm_count) or nil,
    turbines = turbines,
  }
end

local function broadcast_status(status_level)
  comms:publish_status(build_status_payload(status_level))
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
    -- Fix (2026-07-13): RT-P1.3 (siehe docs/CODING_AI_OTHER_NODES_
    -- PERFORMANCE_2026-07-12.md). get_target_rpm() liegt tatsaechlich in
    -- turbine_control (siehe Zeile ~671/732 weiter unten, dort korrekt
    -- verwendet), nicht in reactor_control -- reactor_control.get_
    -- target_rpm existiert nicht, ist also immer nil, wodurch dieser
    -- "and"-Ausdruck IMMER auf den statischen Default (ctx.CONFIG.
    -- TARGET_RPM oder CONFIG.TARGET_RPM, z.B. 900) zurueckfiel, egal
    -- welchen Sollwert MASTER tatsaechlich gerade vorgibt. Der Monitor
    -- zeigte dadurch praktisch immer denselben statischen Wert an.
    get_target_rpm = function() return turbine_control.get_target_rpm(ctx) end,
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
    capacity_learning    = ctx and ctx.capacity_learning or capacity_learning_state,
    constants            = constants,
    targets              = ctx and ctx.targets or {},
    -- Fix (2026-07-01): target_power und target_percent fehlten im Model —
    -- monitor_ui.lua liest model.target_power direkt, nicht model.targets.power.
    -- Ohne diese Felder zeigte die RT-UI dauerhaft "Soll 0.0" und
    -- "WARTET AUF AUFTRAG" obwohl der Node korrekt unter Master-Steuerung lief.
    -- ctx.targets.power wird in command_handler.lua bei SET_SETPOINTS gesetzt:
    -- targets.power = capacity * pct / 100 (absoluter RF/t-Sollwert).
    target_power         = ctx and ctx.targets and ctx.targets.power or 0,
    target_percent       = ctx and ctx.targets and ctx.targets.power_percent or 0,
    node_state_machine   = node_state_machine,
    registry             = registry,
    last_command_ts      = last_command_ts,
    build_label          = function(a, b) return tostring(a or "") .. tostring(b or "") end,
    manifest_id          = RT_BUILD_INFO.manifest_id,
    release_id           = RT_BUILD_INFO.release_id,
  })
end

-- ── Control-Tick ──────────────────────────────────────────────────────────────

local rt_update_quiescing = false

local function control_tick()
  -- A dedicated safe-state writer owns the hardware from the first update
  -- quiesce attempt onward. Normal regulation/startup must not race it.
  if rt_update_quiescing then return end
  -- Fix (2026-07-16): CRITICAL (MASTER-P0, siehe docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md). module_lifecycle.process_startup() war im
  -- gesamten Projekt nirgends verdrahtet (toter Code) -- start_module()
  -- setzte module.state="STARTING"/active_startup, aber ohne process_
  -- startup() progressierte kein Modul jemals weiter Richtung STABLE, egal
  -- wie oft der Control-Tick lief. process_startup() ist ein billiger No-Op
  -- (frueher Return), solange kein Startup aktiv ist (ctx.get_active_
  -- startup() == nil), daher unbedenklich jeden Tick aufzurufen.
  --
  -- Fix (2026-07-17): CRITICAL (RT-P0, siehe docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md Abschnitt 13). module_lifecycle.update_
  -- module_states() existierte bereits, war aber im gesamten Projekt
  -- nirgends verdrahtet -- die einzige Fundstelle war ein Test. Ohne sie
  -- liefen STABLE->RUNNING-Uebergaenge, laufende Modul-Limitbewertung
  -- (TEMP/WATER-Grenzwerte, die module.state=ERROR + SAFE/EMERGENCY
  -- ausloesen), der Modulstate LIMITED sowie modulbezogene Temperatur-/
  -- Coolant-Transitionen NIE ausser waehrend eines aktiven Startups (dort
  -- deckt check_interlocks() innerhalb process_startup() nur EINEN Teil
  -- derselben Pruefung ab). Reihenfolge bewusst SICHERHEITSERST: update_
  -- module_states() (erkennt/reagiert auf neue Gefahrenzustaende ueber
  -- ALLE Module) laeuft VOR process_startup() (treibt nur das aktuell
  -- startende Modul voran) und VOR reactor_control/turbine_control (die
  -- eigentliche Regelung darf nicht auf einem in diesem Tick bereits
  -- veralteten Sicherheitszustand aufbauen).
  module_lifecycle.update_module_states(make_lifecycle_ctx())
  module_lifecycle.process_startup(make_lifecycle_ctx())
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
    -- Fix (2026-07-16): CRITICAL (MASTER-P0, siehe docs/CODING_AI_OTHER_
    -- NODES_PERFORMANCE_2026-07-12.md). Waren bisher No-Ops -- MASTER-
    -- ausgeloeste STARTUP_STAGE/REQUEST_STARTUP_MODULE-Kommandos (siehe
    -- command_handler.lua startup_stage()) liefen dadurch immer ins Leere
    -- (module=nil -> "Unknown module"-Fehlerpfad existierte nicht einmal,
    -- der Aufruf tat schlicht nichts und meldete stillschweigend Erfolg).
    -- make_lifecycle_ctx() liefert bereits ctx.modules=modules_registry und
    -- die echten get_active_startup/set_active_startup-Closures.
    request_startup_if_needed = function(reason)
      local lctx = make_lifecycle_ctx()
      lctx.get_node_state_machine = function() return node_state_machine end
      return state_handlers.request_startup_if_needed(lctx, reason)
    end,
    start_module = function(module_id, module_type, ramp_profile)
      return module_lifecycle.start_module(make_lifecycle_ctx(), module_id, module_type, ramp_profile)
    end,
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
    -- Feature (2026-07-06): Zielwert fuer die individuelle Pro-Reaktor-
    -- Regelung per Command aenderbar und persistent in config/rt.lua
    -- gespeichert, analog zum on_scale_change-Callback fuer die Monitor-
    -- Skalierung. Wirkt sich erst beim naechsten Regelzyklus aus (reactor_
    -- control.lua liest ctx.config.rails.reactor_fill_target jeden Tick
    -- frisch, kein Cache noetig).
    -- Fix (2026-07-17): RT-P1 (siehe docs/CODING_AI_OTHER_NODES_
    -- PERFORMANCE_2026-07-12.md Abschnitt 14). write_config()'s Ergebnis
    -- wurde bisher komplett verworfen (`pcall(...)` ohne jede Auswertung
    -- des Rueckgabewerts) und "changed"/INFO wurde IMMER geloggt, selbst
    -- bei einem fehlgeschlagenen Schreibversuch -- das Command wurde ueber
    -- command_handler.lua's Rueckgabe von `nil` (-> `{ ok = true }`) auch
    -- gegenueber MASTER als vollstaendig angewendet quittiert. Gibt jetzt
    -- das echte Persistenzresultat zurueck, damit der Aufrufer (siehe
    -- SET_REACTOR_FILL_TARGET in command_handler.lua) ein ehrliches
    -- `persisted`-Feld ins ACK_APPLIED-Ergebnis aufnehmen kann.
    set_reactor_fill_target = function(value)
      config.rails = config.rails or {}
      config.rails.reactor_fill_target = value
      local ok_write, werr = utils.write_config(CONFIG.CONFIG_PATH, config)
      if not ok_write then
        log("WARN", ("SET_REACTOR_FILL_TARGET: Persistierung fehlgeschlagen (%s) -- Wert gilt nur bis zum naechsten Neustart"):format(tostring(werr)))
      else
        log("INFO", ("Reactor fill target changed to %.0f%%"):format(value * 100))
      end
      return ok_write == true
    end,
    log = log,
    capacity_learning = ctx and ctx.capacity_learning or capacity_learning_state,
  }
end

-- ── Init ─────────────────────────────────────────────────────────────────────

local function configure_lifecycle_context()
  make_lifecycle_ctx = function()
    return {
      -- State
      STATE             = STATE,
      log               = log,
      warn_once         = warn_once,
      config            = config,
      constants         = constants,
      comms             = comms,
      modules           = modules_registry,
      peripherals       = devices,
      configured_reactors = runtime_config.configured_reactors,
      configured_turbines = runtime_config.configured_turbines,
      binding           = require("nodes.rt.binding"),
      -- State-Machine
      get_current_state    = current_state,
      current_state        = current_state,
      node_state_machine   = node_state_machine,
      setState             = function(s) current_state_value = s end,
      -- Targets
      targets           = ctx and ctx.targets or {},
      -- Turbinen/Reaktor-Funktionen (aus den neuen Modulen)
      get_turbine_ctrl  = function(name) return turbine_control.get_turbine_ctrl(ctx, name) end,
      get_device_caps   = function(k,n) return turbine_control.get_device_caps(ctx, k, n) end,
      get_target_rpm    = function() return turbine_control.get_target_rpm(ctx) end,
      clamp_turbine_flow = function(r) return turbine_control.clamp_turbine_flow(ctx, r) end,
      setTurbineFlow    = function(t,c,r) return turbine_control.setTurbineFlow and
                           turbine_control.setTurbineFlow(ctx,t,c,r) end,
      setTurbineActive  = function(t,c,a) return turbine_control.setTurbineActive(ctx,t,c,a) end,
      update_inductor_for_rpm = function(n,t,c,r,tr)
        return turbine_control.update_inductor_for_rpm(ctx,n,t,c,r,tr) end,
      update_turbine_flow_state = function(r,tr,ctrl)
        return turbine_control.update_turbine_flow_state(ctx,r,tr,ctrl) end,
      ensure_reactor_ctrl = function(n) return reactor_control.ensure_reactor_ctrl(ctx,n) end,
      get_effective_regulator_rod_caps = function()
        return reactor_control.get_effective_regulator_rod_caps(ctx) end,
      applyReactorRods  = function(t,o,s) return reactor_control.applyReactorRods(ctx,t,o,s) end,
      setReactorActive  = function(r,c,a) return reactor_control.setReactorActive(ctx,r,c,a) end,
      read_current_rods = function() return reactor_control.read_current_rods(ctx) end,
      evaluate_reactor_coolant = function(r,s)
        return reactor_control.evaluate_reactor_coolant(ctx,r,s) end,
      ramp_towards      = function(c,t,s) return reactor_control.ramp_towards(c,t,s) end,
      -- Fix (2026-07-16): CRITICAL (MASTER-P0). Waren bisher No-Ops -- echte
      -- Closures auf die modul-globalen Startup-State-Variablen (siehe oben
      -- "local active_startup_id" etc.), damit start_module()/process_
      -- startup() Zustand tatsaechlich lesen/schreiben koennen.
      get_active_startup           = function() return active_startup_id end,
      set_active_startup           = function(id) active_startup_id = id end,
      get_startup_queue            = function() return startup_queue_list end,
      set_startup_queue            = function(q) startup_queue_list = q or {} end,
      get_startup_started_ms       = function() return startup_started_ms_value end,
      set_startup_started_ms       = function(ms) startup_started_ms_value = ms end,
      get_startup_watchdog_tripped = function() return startup_watchdog_tripped_value end,
      set_startup_watchdog_tripped = function(v) startup_watchdog_tripped_value = v end,
      add_alarm    = function(_, sev, msg) if comms then comms:send_alert(sev, msg) end end,
      -- CC:Tweaked CONFIG-Werte
      START_FLOW   = CONFIG.START_FLOW   or 100,
      RPM_TOL      = CONFIG.RPM_TOLERANCE or 15,
      -- Fix (2026-07-17): CRITICAL (RT-P0, siehe docs/CODING_AI_OTHER_NODES_
      -- PERFORMANCE_2026-07-12.md Abschnitt 11). Hiess bisher "TURBINE_MODE"
      -- und war ein reiner STRING (CONFIG.TURBINE_MODE_RAMP ist selbst ein
      -- String, z.B. "RAMP") -- module_lifecycle.lua indizierte diesen Wert
      -- aber als Tabelle (ctx.TURBINE_MODE.RAMP), was im echten Produktions-
      -- Context zu "attempt to index a string value" fuehrte bzw. (falls
      -- durch pcall/Fehlerpfad verdeckt) ctrl.mode nie zuverlaessig auf den
      -- vorgesehenen Rampenmodus setzte. Konsistent mit turbine_control.lua's
      -- eigener Konvention (ctx.CONFIG.TURBINE_MODE_RAMP, ueberall ein reiner
      -- String -- siehe z.B. dessen Zeile mit "ctrl.mode = ctx.CONFIG.
      -- TURBINE_MODE_RAMP or \"RAMP\"") umbenannt zu TURBINE_MODE_RAMP,
      -- weiterhin ein String -- module_lifecycle.lua liest jetzt direkt
      -- ctx.TURBINE_MODE_RAMP statt ctx.TURBINE_MODE.RAMP.
      TURBINE_MODE_RAMP = CONFIG.TURBINE_MODE_RAMP or "RAMP",
      -- Fix (2026-07-17): CRITICAL (RT-P0, siehe docs/CODING_AI_OTHER_NODES_
      -- PERFORMANCE_2026-07-12.md Abschnitt 12). Dieser Diagnose-Stub gab
      -- bisher "30" zurueck, benannt als "ramp_duration" -- ohne jede
      -- Einheit im Namen. module_lifecycle.lua's process_startup() rechnet
      -- aber mit "(now - module.start_time) / duration", wobei "now" und
      -- "start_time" beide os.epoch("utc") in MILLISEKUNDEN sind -- die
      -- Reaktorrampe erreichte dadurch bereits nach ~30 Millisekunden 100%
      -- Fortschritt statt der beabsichtigten 30 SEKUNDEN, ein klarer
      -- Widerspruch zum 60s-Startup-Stage-Timeout (siehe VALVE_PHASE_
      -- TIMEOUT_MS-aehnliche Deadlines) und zur fachlichen Bedeutung einer
      -- Rampe. Jetzt explizit als Sekunden benannt und einmalig in
      -- Millisekunden umgerechnet -- "ramp_duration_ms" liefert garantiert
      -- Millisekunden, keine unbenannte Zahlenkonstante mehr.
      ramp_duration_ms = function(_ramp_profile)
        local STARTUP_RAMP_DURATION_S = 30
        return STARTUP_RAMP_DURATION_S * 1000
      end,
      warn_unsupported = function(name, reason)
        warn_once("unsupported:" .. tostring(name),
          "Device unsupported: " .. tostring(name) .. " (" .. tostring(reason or "") .. ")")
      end,
    }
  end
end

local function configure_state_machine()
  local state_ctx = {
    -- Basis
    STATE             = STATE,
    config            = config,
    constants         = constants,
    log               = log,
    comms             = comms,
    devices           = devices,
    modules           = modules_registry,
    targets           = ctx and ctx.targets or {},
    TARGET_RPM        = CONFIG.TARGET_RPM,
    -- Zustands-Accessoren
    get_current_state      = current_state,
    set_current_state      = function(v) current_state_value = v end,
    get_node_state_machine = function() return node_state_machine end,
    allowed_transitions    = nil,
    -- Regelungs-Callbacks
    adjust_turbines   = function() turbine_control.updateControl(ctx) end,
    adjust_reactors   = function() reactor_control.updateReactorControl(ctx) end,
    get_target_rpm    = function() return turbine_control.get_target_rpm(ctx) end,
    ramp_towards      = function(c,t,s) return reactor_control.ramp_towards(c,t,s) end,
    clamp_autonom_targets = function()
      if ctx and ctx.targets then
        local t = ctx.targets
        t.power   = math.max(0, t.power   or 0)
        t.steam   = math.max(0, t.steam   or 0)
        t.rpm     = math.max(0, t.rpm     or CONFIG.TARGET_RPM)
      end
    end,
    -- Master-Monitoring
    monitor_master = function()
      if not is_master_connected() then
        if current_state() == STATE.MASTER then
          log("WARN", "Master disconnected — switching to AUTONOM")
          current_state_value = STATE.AUTONOM
        end
      end
    end,
    -- Alarm
    add_alarm = function(_, sev, msg)
      if comms then comms:send_alert(sev, msg) end
    end,
    -- Fix (2026-07-16): CRITICAL (MASTER-P0, siehe docs/CODING_AI_OTHER_NODES_
    -- PERFORMANCE_2026-07-12.md). Waren bisher No-Ops ("RT-Node hat keine
    -- Modul-Startup-Sequenz") -- dadurch blieb der STARTUP-State (siehe
    -- state_handlers.lua startup_on_enter/startup_on_tick) permanent
    -- funktionslos: die Warteschlange wurde zwar befuellt, aber start_module()
    -- tat nichts, also blieb jedes Modul fuer immer OFF und der Node kam nie
    -- nach RUNNING. Echte Closures auf die modul-globalen Startup-State-
    -- Variablen (siehe "local active_startup_id" etc. oben).
    get_active_startup           = function() return active_startup_id end,
    set_active_startup           = function(id) active_startup_id = id end,
    get_startup_queue            = function() return startup_queue_list end,
    set_startup_queue            = function(q) startup_queue_list = q or {} end,
    get_startup_started_ms       = function() return startup_started_ms_value end,
    set_startup_started_ms       = function(ms) startup_started_ms_value = ms end,
    get_startup_watchdog_tripped = function() return startup_watchdog_tripped_value end,
    set_startup_watchdog_tripped = function(v) startup_watchdog_tripped_value = v end,
    reset_startup_watchdog       = function()
      startup_watchdog_tripped_value = false
      startup_started_ms_value = nil
    end,
    -- handle_startup_timeout() erwartet direkte Felder (nicht Getter/Setter)
    -- fuer startup_watchdog_tripped/startup_started_ms, siehe startup_
    -- diagnostics.lua -- baut deshalb einen eigenen kleinen Snapshot-Context
    -- statt make_lifecycle_ctx()/state_ctx direkt wiederzuverwenden. node_
    -- state_machine ist eine Tabellen-Referenz (mutiert von state_machine.lua
    -- direkt) -- kein manueller Rueckschreib-Sync fuer die state()/transition()-
    -- Aufrufe darin noetig, nur fuer den tripped-Flag (einfacher Boolean-Wert,
    -- kein Referenztyp).
    handle_startup_timeout = function()
      local diag_ctx = {
        startup_watchdog_tripped = startup_watchdog_tripped_value,
        startup_started_ms       = startup_started_ms_value,
        comms                    = comms,
        config                   = config,
        devices                  = devices,
        registry                 = registry,
        log                      = log,
        update_status_snapshot   = update_status_snapshot,
        constants                = constants,
        broadcast_status         = broadcast_status,
        node_state_machine       = node_state_machine,
        set_active_startup       = function(id) active_startup_id = id end,
        set_startup_queue        = function(q) startup_queue_list = q or {} end,
      }
      local tripped = startup_diagnostics.handle_startup_timeout(diag_ctx)
      if tripped then
        startup_watchdog_tripped_value = true
      end
    end,
    start_module = function(module_id, module_type, ramp_profile)
      return module_lifecycle.start_module(make_lifecycle_ctx(), module_id, module_type, ramp_profile)
    end,
    -- Lifecycle-Funktionen (delegieren an module_lifecycle mit vollem Context)
    scram = function()
      module_lifecycle.scram(make_lifecycle_ctx())
    end,
    apply_safe_controls = function()
      module_lifecycle.apply_safe_controls(make_lifecycle_ctx())
    end,
    set_reactors_active = function(active, reason)
      local lctx = make_lifecycle_ctx()
      module_lifecycle.set_reactors_active(lctx, active, reason)
    end,
    set_turbines_active = function(active, reason)
      local lctx = make_lifecycle_ctx()
      module_lifecycle.set_turbines_active(lctx, active, reason)
    end,
  }
  -- Fix (2026-07-15): expliziter Guard + Diagnose-Log fuer is_master_connected,
  -- bevor state_handlers.build() dessen eigenen generischen (aber weniger
  -- aussagekraeftigen) assert_fn-Guard auswertet -- gibt Operatoren beim RT-
  -- Boot eine eindeutige Bestaetigung, dass der sicherheitskritische Master-
  -- Failover-Check verdrahtet ist.
  state_ctx.is_master_connected = is_master_connected
  if type(state_ctx.is_master_connected) ~= "function" then
    error("rt state context missing required function: is_master_connected", 0)
  end
  log("INFO", "State context ready (is_master_connected=true)")
  states_table = state_handlers.build(state_ctx)
  node_state_machine = machine.new(states_table, constants.node_states.OFF)

  -- Initiale Mode: AUTONOM
  current_state_value = STATE.AUTONOM
  node_state_machine:transition(constants.node_states.RUNNING)
end
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
        local was_connected = master_seen_ts ~= nil
        master_seen_ts = os.epoch("utc")
        if message.type == constants.message_types.STATUS
            and message.payload and message.payload.alerts then
          master_alerts = message.payload.alerts
        end
        if not was_connected then
          log("INFO", "Master connected: " .. tostring(message.role or "?"))
        end
      end
    end
  })
  services:add(comms)

  services:add(discovery_service.new({
    registry = registry,
    discover = discover_with_stability_tracking,
    should_discover = should_discover,
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

  configure_lifecycle_context()
  configure_state_machine()

  -- Monitor initialisieren
  local mon_entry = adapters.monitor.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  devices.monitor = mon_entry and mon_entry.mon or nil
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current()
  end
  monitor_ui.init(devices.monitor, config.monitor, config.monitor_scale)

  -- Feature (2026-07-05): Monitor-Skalierung per Touch auf der
  -- Diagnostics-Seite einstellbar (statt nur ueber config/rt.lua von Hand
  -- editierbar). ctx.monitor_scale wird von monitor_ui.lua ins Model
  -- gelesen und angezeigt; dieser Callback wendet eine Aenderung sofort
  -- live an (ui.setScale via monitor_adapter/try_set_scale-Pfad in
  -- monitor_ui.lua selbst reagiert automatisch beim naechsten Render, da
  -- M.init erneut aufgerufen wird) und persistiert sie in config/rt.lua,
  -- damit sie einen Reboot ueberlebt.
  ctx.monitor_scale = config.monitor_scale
  monitor_ui.on_scale_change = function(delta)
    local cur = tonumber(ctx.monitor_scale) or tonumber(config.monitor_scale) or 0.5
    local new_scale = math.max(0.5, math.min(5, cur + delta))
    ctx.monitor_scale = new_scale
    config.monitor_scale = new_scale
    monitor_ui.set_scale(devices.monitor, new_scale)
    pcall(utils.write_config, CONFIG.CONFIG_PATH, config)
    log("INFO", ("Monitor scale changed to %.1f"):format(new_scale))
  end

  -- Hello + erster Heartbeat
  log("INFO", string.format("HELLO sent: reactors=%d turbines=%d",
    #devices.reactors, #devices.turbines))
  comms:send_hello({
    reactors = #devices.reactors,
    turbines  = #devices.turbines,
  })
  build_status_payload(constants.status_levels.OK)

  -- Startup-Diagnose-Report (Kernfunktion, 2026-07-01): siehe
  -- xreactor/core/startup_report.lua. Kein pcall(require, ...) mehr noetig
  -- — das Modul ist immer installiert (kein Opt-in), require() darf hier
  -- also normal fehlschlagen (mit klarem Fehler) falls es fehlt, statt
  -- den Fehlerzustand still zu verschlucken. Der eigentliche Aufruf bleibt
  -- trotzdem in pcall() gewrappt, da einzelne Peripheral-Abfragen darin
  -- (z.B. Modem-Erkennung) theoretisch scheitern koennten — der Boot-
  -- Vorgang selbst darf davon nie blockiert werden.
  local report_mod = require("core.startup_report")
  pcall(function()
    local checks = { report_mod.check_wireless_modem() }
    local summary = registry and registry.get_summary and registry:get_summary() or {}
    local kinds = summary.kinds or {}
    local reactors = kinds.reactor or {}
    local turbines = kinds.turbine or {}
    checks[#checks + 1] = { name = "Reaktor erkannt", ok = (reactors.bound or 0) > 0,
      detail = string.format("%d/%d gebunden", reactors.bound or 0, reactors.total or 0) }
    checks[#checks + 1] = { name = "Turbinen erkannt", ok = (turbines.bound or 0) > 0,
      detail = string.format("%d/%d gebunden", turbines.bound or 0, turbines.total or 0) }
    checks[#checks + 1] = { name = "Monitor gefunden", ok = devices.monitor ~= nil }
    -- Fix (2026-07-13): RT-P1.2 (siehe docs/CODING_AI_OTHER_NODES_
    -- PERFORMANCE_2026-07-12.md). config.role ist immer "RT-NODE" (siehe
    -- nodes/rt/config.lua), niemals das kurze "RT" -- dieser Vergleich
    -- schlug dadurch IMMER fehl, selbst bei korrekt konfigurierter Rolle,
    -- und zeigte "Rolle konfiguriert" faelschlich als Fehler im Startup-
    -- Report an.
    checks[#checks + 1] = { name = "Rolle konfiguriert", ok = tostring(config.role or "") == "RT-NODE" }
    -- Speaker (Feature, 2026-07-02): optional, pcall(require, ...) da nicht
    -- immer installiert. Der Speaker-Effekt gilt jetzt fuer JEDEN Node-Typ,
    -- nicht nur MASTER (dort ursprungl. nur fuer CRITICAL-Alarme gedacht).
    local ok_spk, spk_mod = pcall(require, "optional.speaker_alarm")
    local speaker = ok_spk and spk_mod.new() or nil
    report_mod.run(checks, { log = log, speaker = speaker })
  end)

  log("INFO", "RT-Node ready: " .. (comms.network and comms.network.id or node_id))
end

-- ── Start ────────────────────────────────────────────────────────────────────

init()

-- Fix (2026-07-05): discover() lief bisher NUR EINMAL beim Boot (in
-- init()). Falls beim allerersten Scan Peripherals noch nicht bereit
-- waren (Chunk laedt noch, Ender-Modem noch nicht stabil) oder aus
-- anderem Grund devices.reactors/turbines leer blieben, gab es NIE einen
-- zweiten Versuch — waehrend die Registry selbst (ctx.registry, von
-- Overview genutzt) unter Umstaenden ueber einen anderen Pfad dennoch
-- aktuelle Werte zeigte. Das erklaerte den beobachteten Widerspruch:
-- Overview zeigte "25 Turbinen", die Turbinen-Detailseite zeigte "0" —
-- beide lasen aus derselben Registry, aber devices.turbines/reactors
-- Fix (2026-07-13): CRITICAL (RT-P1.1, siehe docs/CODING_AI_OTHER_
-- NODES_PERFORMANCE_2026-07-12.md). Der 60s-Fallback hier war reine
-- Redundanz: discovery_service (siehe services:add(discovery_service.
-- new({...interval = config.scan_interval...})) weiter oben) ruft
-- DIESELBE discover()-Funktion bereits alle config.scan_interval (=10s)
-- Sekunden auf -- UNABHAENGIG vom Erfolg des vorherigen Versuchs (siehe
-- discovery_service.lua:tick(), retried bei jedem Intervall neu, kein
-- "stop nach erstem Erfolg"-Verhalten). Der zusaetzliche manuelle 60s-
-- Aufruf hier lief also strikt SELTENER als der ohnehin schon aktive
-- Pfad und trug nichts zur Selbstkorrektur bei, verursachte aber
-- unnoetige doppelte volle Discovery-Durchlaeufe.

local quiesce_handshake = _G.__xreactor_update_handshake
local last_quiesce_warning = 0

local function update_quiesce_safe()
  rt_update_quiescing = true
  active_startup_id = nil
  startup_queue_list = {}
  startup_started_ms_value = nil
  startup_watchdog_tripped_value = false
  current_state_value = STATE.SAFE
  if node_state_machine then pcall(node_state_machine.transition, node_state_machine, STATE.SAFE) end

  if ctx and ctx.targets then
    ctx.targets.power = 0
    ctx.targets.power_percent = 0
    ctx.targets.steam = 0
    ctx.targets.enable_reactors = false
    ctx.targets.enable_turbines = false
  end
  for _, module in pairs(modules_registry) do
    if type(module) == "table" and module.state == "STARTING" then
      module.state = "OFF"
      module.progress = 0
    end
  end

  local reactors_ok = select(1, reactor_control.apply_update_quiesce(ctx))
  local turbines_ok = select(1, turbine_control.apply_update_quiesce(ctx))
  if reactors_ok ~= true or turbines_ok ~= true then
    local now = os.epoch("utc")
    if now - last_quiesce_warning >= 2000 then
      last_quiesce_warning = now
      log("WARN", "UPDATE_QUIESCE wartet auf bestaetigte Hardware-Readbacks"
        .. " reactors=" .. tostring(reactors_ok)
        .. " turbines=" .. tostring(turbines_ok))
    end
    return false
  end

  writeback_ctx()
  log("INFO", "UPDATE_QUIESCE bestaetigt: Rods voll eingefahren, Reaktoren aus, Turbinenflow 0")
  return true
end

support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() end,
  quiesce_handshake and {
    handshake = quiesce_handshake,
    on_quiesce = update_quiesce_safe,
  } or nil)
