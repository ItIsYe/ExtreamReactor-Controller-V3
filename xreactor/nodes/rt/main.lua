-- nodes/rt/main.lua  (RT-Node Rewrite — SCADA-Architektur)
--
-- Orchestrierungsschicht: Boot, Services, Event-Loop. Sie regelt nichts.
--
-- Die gesamte Regelung liegt hinter EINEM Aufruf -- rt2_engine.tick() --
-- und nur dort. Der frueher parallel existierende v1-Regler (Steam-Margin-
-- Regler, Turbinen-Rampe, Modul-Lebenszyklus, Startup-Warteschlange,
-- Knoten-Zustandsmaschine, eigenes Capacity-Learning) ist vollstaendig
-- entfernt: er war nicht mehr erreichbar, konnte die Regelung aber ueber
-- gemeinsamen Zustand stoeren, und zwei Wahrheiten ueber denselben
-- Reaktor sind eine zu viel.
--
-- Was hier noch liegt:
--   rt2_engine.lua        — der Regler (lesen, entscheiden, schreiben)
--   reactor_control.lua   — Reaktor-Hardwarezugriff (Rods, Dampf, Quiesce)
--   turbine_control.lua   — Turbinen-Hardwarezugriff (Drehzahl, Flow, Quiesce)
--   status_snapshot.lua   — Status-Payload fuer Master
--   monitor_ui.lua        — lokaler Monitor-Renderer

-- ── Konstanten ───────────────────────────────────────────────────────────────

local CONFIG = {
  LOG_NAME           = "rt",
  LOG_PREFIX         = "RT",
  NODE_ID_PATH       = "/xreactor_config/node_id.txt",
  CONFIG_PATH        = nil,          -- wird von role_descriptor befüllt
  -- 0.1s so the scheduler cycle (which drives the reactor/turbine control
  -- tick) meets the required 10Hz cadence; other periodic services gate on
  -- their own interval and are unaffected.
  RECEIVE_TIMEOUT    = 0.1,
  -- Rod-Grenzen des HARDWARE-Zugriffs (nicht des Reglers: rt2_reactor.lua
  -- hat mit ROD_MIN = 70 seine eigene, bewusst engere Leistungsgrenze).
  ROD_MIN            = 0,
  ROD_MAX            = 100,
  INITIAL_ROD_LEVEL  = 100,
  -- Flow-Grenzen fuer clamp_turbine_flow() und die Config-Validierung.
  -- Die Regelgrenzen liegen in rt2_turbine.lua (MIN_FLOW/MAX_FLOW dort).
  TARGET_RPM         = 900,
  MIN_FLOW           = 0,
  MAX_FLOW           = 32000,
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
local safety          = require("core.safety")
local fluid           = require("core.fluid")
local registry_lib    = require("core.registry")
local service_manager = require("services.service_manager")
local comms_service   = require("services.comms_service")
local telemetry_service = require("services.telemetry_service")
local discovery_service = require("services.discovery_service")
local ui_service      = require("services.ui_service")
local support_runtime = require("nodes.support.runtime")
local binding         = require("nodes.rt.binding")
local config_normalizer = require("nodes.rt.config_normalizer")
local monitor_ui      = require("nodes.rt.monitor_ui")
local status_snapshot_lib = require("nodes.rt.status_snapshot")
local discovery_runtime   = require("nodes.rt.discovery_runtime")
local health_payload      = require("nodes.rt.health_payload")
-- DER Regler der RT-Node. Kein Schalter mehr, keine Alternative: init()
-- initialisiert ihn, control_tick() tickt ihn, build_status_payload() und
-- update_monitor() lesen aus ihm.
local rt2_engine          = require("nodes.rt.rt2_engine")

-- Hardware-Zugriff (keine Regelung, siehe die Modulkoepfe dort)
local reactor_control   = require("nodes.rt.reactor_control")
local turbine_control   = require("nodes.rt.turbine_control")

local adapters = {
  reactor = require("adapters.reactor"),
  turbine  = require("adapters.turbine"),
  monitor  = require("adapters.monitor"),
}
local rt_default_config = require("nodes.rt.config")

-- ── Config ───────────────────────────────────────────────────────────────────

CONFIG.CONFIG_PATH = "/xreactor_config/rt.lua"
local DEFAULT_CONFIG = utils.deep_copy(rt_default_config)
local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local reactor_names = utils.load_config("/xreactor_config/reactor_names.lua", {
  version = 2, completed = false, aliases = {}, reactors = {},
})
if type(reactor_names) ~= "table" or reactor_names.completed ~= true
    or type(reactor_names.aliases) ~= "table" then
  reactor_names = { aliases = {} }
end
local config_warnings = {}
local function add_config_warning(msg) table.insert(config_warnings, msg) end
config_normalizer.migrate_legacy_paths(config, add_config_warning)
-- Migrates known historical default values (pre-10Hz-fix) to the current
-- 0.10 defaults, gated on config.version so it runs and persists only once.
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

-- Nur noch das, was der Hardware-Zugriff (nodes/rt/reactor_control.lua,
-- nodes/rt/turbine_control.lua) ueber Takte hinweg braucht. Die Regelung
-- selbst haelt ihren Zustand ausschliesslich in rt2_engine.lua -- v1s
-- Regel-State (Rails-EMA, Steam-Guard, Rod-Richtung/-Historie) ist mit v1
-- entfallen.
local state = {
  last_applied_rods       = nil,
  last_rod_apply_ts       = 0,
  steam_tank_name         = nil,
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
-- Separate from `devices`: devices.reactors/.turbines hold the registry
-- ENTRY LIST ({id,name,kind,bound,...}, iterated with ipairs by
-- monitor_ui.lua and discovery_runtime.build_modules()),
-- while peripheral_cache.reactors/.turbines hold the wrapped CC:Tweaked
-- peripheral objects keyed by NAME (looked up by reactor_control.lua/
-- turbine_control.lua). These must stay two distinct
-- tables -- aliasing them let discovery_runtime.M.cache()'s peripheral-map
-- write silently overwrite devices.reactors/.turbines with a name-keyed map,
-- so every ipairs() consumer above saw zero entries and modules_registry
-- got wiped empty on every binding change.
local peripheral_cache = { reactors = {}, turbines = {} }
local master_seen_ts = nil
local master_alerts  = {}

-- Computed once at module load instead of on every status-snapshot call
-- (hot path) to avoid repeated require()/dofile() I/O.
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

local comms, services, slow_services
-- Betriebsmodus-Anzeige (INIT/AUTONOM/MASTER/SAFE). Die echte Regelung
-- kennt diesen Wert nicht -- sie lebt vollstaendig in rt2_engine.lua; hier
-- steht er nur fuer Telemetrie und den lokalen Schirm, und rt2_engine's
-- status_fields() ueberschreibt ihn, sobald es einen Modus meldet.
local current_state_value = "INIT"

local STATE = {
  INIT   = "INIT", AUTONOM = "AUTONOM",
  MASTER = "MASTER", SAFE = "SAFE"
}

local warned = {}
local last_command, last_command_ts
local last_status_snapshot
-- Geraete-Verzeichnis fuer Telemetrie/UI (discovery_runtime.build_modules()).
-- Es traegt keinen Lebenszyklus mehr: v1s Startup-Warteschlange, Ramp-
-- Zustaende und der Startup-Watchdog sind mit v1 entfallen. rt2_engine.lua
-- faehrt Reaktoren und Turbinen ohne Startup-Sequenz hoch -- es regelt vom
-- ersten Takt an aus dem Dampf-Fuellstand.
local modules_registry = {}

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

-- Die Master-Verbindung wird nicht mehr hier bewertet: rt2_master_link.lua
-- fuehrt sie, gespeist aus note_master_seen() (siehe comms on_message in
-- init()). Die frueher hier stehenden Helfer is_master_connected() und
-- master_peer_state() waren v1s zweite Meinung darueber -- genau die Art
-- doppelter Wahrheit, die dieser Umbau beseitigt.

-- ── ctx-Builder ───────────────────────────────────────────────────────────────
-- Baut das ctx-Objekt, das alle Fachmodule bekommen.
-- Statt vieler lokaler Closures hat jede Funktion jetzt eine explizite
-- Abhängigkeitsliste am Kopf (ctx.*).

-- Der ctx traegt nur noch, was der Hardware-Zugriff braucht: Peripherie,
-- Capability-Cache, Konfiguration, Logging. Die Regelung bekommt ihn nicht
-- mehr -- rt2_engine.lua liest die Hardware ueber nodes/rt/rt2_adapter.lua
-- und haelt seinen Zustand selbst.
local function build_ctx()
  return {
    last_applied_rods         = state.last_applied_rods,
    last_rod_apply_ts         = state.last_rod_apply_ts,
    steam_tank_name           = state.steam_tank_name,
    peripherals               = peripheral_cache,
    modules                   = modules_registry,
    reactor_ctrl              = {},   -- wird in init_reactor_ctrl befuellt
    turbine_ctrl_store        = {},   -- wird in init_turbine_ctrl befuellt
    capability_cache          = { reactors = {}, turbines = {} },
    -- Config
    config  = config,
    CONFIG  = CONFIG,
    -- Module
    adapters          = adapters,
    safety            = safety,
    fluid             = fluid,
    utils             = utils,
    binding           = binding,
    runtime_config    = runtime_config,
    reactor_control   = reactor_control,
    -- Funktionen
    log               = log,
    warn_once         = warn_once,
    safe_wrapped_call = safe_wrapped_call,
    get_turbine_ctrl  = function(name)
      return turbine_control.get_turbine_ctrl(ctx, name)
    end,
    warned            = {},   -- Dedup-Map fuer warn_once
  }
end

-- ── State-Writeback ───────────────────────────────────────────────────────────
-- ctx ist keine Live-Referenz auf state — nach jedem Tick schreiben wir
-- die mutierten Felder zurück.

-- ctx ist keine Live-Referenz auf state -- nach jedem Hardware-Zugriff
-- schreiben wir die mutierten Felder zurueck. Das Capacity-Learning ist
-- hier ersatzlos entfallen: rt2_capacity.lua fuehrt sein eigenes Lernen und
-- rt2_engine.lua schreibt dessen Cache selbst (rt2_capacity_cache.lua).
local function writeback_ctx()
  state.last_applied_rods = ctx.last_applied_rods
  state.last_rod_apply_ts = ctx.last_rod_apply_ts
  state.steam_tank_name   = ctx.steam_tank_name
end

-- ── Discovery ────────────────────────────────────────────────────────────────

local function build_discovery_context()
  return {
    config = config,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    peripherals = peripheral_cache,
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
    -- M.refresh_bindings() calls these without evaluating a return value,
    -- so modules_registry must be mutated in place, not replaced.
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
      discovery_runtime.refresh_module_peripherals(modules_registry, peripheral_cache, function(kind, name)
        return turbine_control.get_device_caps(ctx, kind, name)
      end)
    end,
  }
end

local function discover()
  discovery_runtime.discover(build_discovery_context())
  devices.last_scan_ts = os.epoch("utc")
  -- CC:Tweaked peripheral names are not guaranteed stable across a wired-
  -- modem reconnect -- if one shifts, reactor_names.lua's name-keyed alias
  -- silently stops matching and this reactor falls back to its technical
  -- ID everywhere downstream (RT's own UI, Master, and FUEL's route
  -- picker, which all read registry entry.alias off the SAME broadcast).
  -- Surface that immediately as a visible warning instead of letting it
  -- look like a name-propagation bug in FUEL/Master.
  if reactor_names.completed == true then
    for _, entry in ipairs(registry:get_bound_devices("reactor")) do
      if not entry.alias then
        warn_once("reactor_no_alias:" .. tostring(entry.name), string.format(
          "Reaktor %s hat keinen zugewiesenen Namen (reactor_names.lua). Moeglich: " ..
          "CC:Tweaked hat den Peripherie-Namen nach einem Reconnect geaendert. " ..
          "Master/FUEL zeigen fuer diesen Reaktor die technische ID statt des Namens.",
          tostring(entry.name)))
      end
    end
  end
end

-- After DISCOVERY_STABLE_STREAK unchanged scans in a row (binding_
-- signature stable), scan only every DISCOVERY_SLOW_MULTIPLIER *
-- scan_interval seconds instead of every scan_interval -- a real change
-- (attach/detach) is caught at the next due scan and resets to the normal
-- cadence immediately. Uses a wall-clock deadline
-- (discovery_next_slow_scan_at), not a call counter, since
-- discovery_service.lua only updates last_scan on an actually-executed
-- scan -- a counter of should_discover() calls would count scheduler
-- ticks (~every 0.1s), not real scan intervals.
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

-- Pure state/no peripheral calls (see nodes/rt/health_payload.lua) -- shared
-- by build_status_payload() (telemetry) and update_monitor() (local UI) so
-- the monitor doesn't have to run a full build_status_payload() sweep
-- (which re-inspects every bound reactor/turbine) just to read out the
-- small .health record.
local function build_rt_health_payload()
  return health_payload.build_health_payload({
    comms = comms, constants = constants,
    -- NICHT auf "jetzt" vorbelegen. master_seen_ts ist nil, solange nie
    -- eine MASTER-Nachricht ankam -- ein Vorbelegen auf die aktuelle Zeit
    -- liess einen nie gesehenen MASTER mit Alter 0 als verbunden
    -- durchgehen (siehe health_payload.is_master_connected).
    master_seen = master_seen_ts,
    hb = config.heartbeat_interval,
    -- Dieselbe Schwelle, die core/comms.lua fuer seine Peer-Tabelle und
    -- rt2_master_link.lua fuer den Betriebszustand benutzt. Drei Schwellen
    -- fuer dieselbe Tatsache waren der Grund fuer "MASTER DOWN auf dem
    -- Schirm, waehrend der Regler im Zustand MASTER laeuft".
    peer_timeout_s = config.comms and config.comms.peer_timeout_s or nil,
    devices = devices, registry = registry, binding = binding,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    health = health, warn_once = warn_once,
    -- v1s Startup-Watchdog gibt es nicht mehr: rt2_engine.lua kennt keine
    -- Startup-Sequenz, die ueberwacht werden muesste. Ein hartes false ist
    -- hier also keine fehlende Meldung, sondern der zutreffende Wert.
    startup_watchdog_tripped = false,
    rt_health = rt_health,
    configured_caps = runtime_config.configured_caps,
  })
end

-- Die Hardware-Aufnahme (Brennstoff, Temperatur, Drehzahl, Zustand der
-- Bindungen) kommt weiter aus status_snapshot.lua -- sie liest Geraete, sie
-- regelt nichts. Alles, was eine ENTSCHEIDUNG ist (Modus, Knotenzustand,
-- Kapazitaet), kommt aus rt2_engine.lua: es gibt nur noch diese eine Quelle.
local function build_status_payload(status_level)
  local v2 = rt2_engine.status_fields()
  local ctx_snap = {
    status_level         = status_level or constants.status_levels.OK,
    current_state        = v2.mode or current_state_value,
    targets              = ctx.targets,
    build_health_payload = build_rt_health_payload,
    devices              = devices,
    registry             = registry,
    modules              = modules_registry,
    turbine_adapter      = adapters.turbine,
    reactor_adapter      = adapters.reactor,
    log_prefix           = CONFIG.LOG_PREFIX,
    log                  = log,
    config               = config,
    -- Felder fuer status_snapshot.build_turbine_snapshots / build_reactor_snapshots
    get_available_steam  = function() return reactor_control.get_available_steam(ctx) end,
    get_device_caps      = function(k,n) return turbine_control.get_device_caps(ctx,k,n) end,
    read_turbine_rpm     = function(t,c) return turbine_control.read_turbine_rpm(ctx,t,c) end,
    read_turbine_flow    = function(t,c) return turbine_control.read_turbine_flow(ctx,t,c) end,
    last_status_snapshot = last_status_snapshot,
    monitor_ui           = monitor_ui,
    status_snapshot      = status_snapshot_lib,
  }
  local payload = status_snapshot_lib.build_status_payload(ctx_snap)
  payload.mode = v2.mode
  payload.control_mode = v2.mode
  if v2.node_state then payload.state = v2.node_state end
  if v2.capacity_ready ~= nil then payload.capacity_ready = v2.capacity_ready end
  if v2.capacity_max then payload.capacity_max = v2.capacity_max end
  if v2.capacity_at_target then payload.capacity_stable_turbines = v2.capacity_at_target end
  if v2.capacity_total_turbines then payload.capacity_total_turbines = v2.capacity_total_turbines end
  if v2.capacity_reason then payload.capacity_source = v2.capacity_reason end
  if v2.capacity_required_turbines then
    payload.capacity_required_turbines = v2.capacity_required_turbines
  end
  -- Wieviele Turbinen liefen, als der gelernte Hoechstwert floss. MASTER
  -- liest das Feld (message_handlers.lua) und zeigt daraus "x von y
  -- Turbinen tragen" an -- gesendet hat es die Node nur nie, seit der
  -- rt2-Regler die Kapazitaet uebernahm. Die Anzeige war damit tot.
  if v2.capacity_sustainable_turbines then
    payload.capacity_sustainable_turbines = v2.capacity_sustainable_turbines
  end
  writeback_ctx()
  return payload
end

local function broadcast_status(status_level)
  comms:publish_status(build_status_payload(status_level))
end

-- ── Monitor ───────────────────────────────────────────────────────────────────

local function update_monitor()
  local mon = devices.monitor
  if not mon then return end
  local monitor_ctx = {
    config = config, devices = devices, registry = registry,
    comms = comms, constants = constants,
    master_alerts = master_alerts,
    last_command = last_command, last_command_ts = last_command_ts,
    current_state = current_state_value,
    configured_reactors = runtime_config.configured_reactors,
    configured_turbines = runtime_config.configured_turbines,
    binding = binding,
    build_health_payload = build_rt_health_payload,
    read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
    read_turbine_flow = function(t, c) return turbine_control.read_turbine_flow(ctx, t, c) end,
    reactor_adapter = adapters.reactor,
    turbine_adapter = adapters.turbine,
    log_prefix = CONFIG.LOG_PREFIX,
    get_device_caps = function(k, n) return turbine_control.get_device_caps(ctx, k, n) end,
    get_available_steam = function() return reactor_control.get_available_steam(ctx) end,
    last_status_snapshot = last_status_snapshot,
    constants            = constants,
    targets              = ctx and ctx.targets or {},
    -- monitor_ui.lua reads model.target_power directly, not model.targets.power.
    target_power         = ctx and ctx.targets and ctx.targets.power or 0,
    target_percent       = ctx and ctx.targets and ctx.targets.power_percent or 0,
    registry             = registry,
    last_command_ts      = last_command_ts,
    build_label          = function(a, b) return tostring(a or "") .. tostring(b or "") end,
    manifest_id          = RT_BUILD_INFO.manifest_id,
    release_id           = RT_BUILD_INFO.release_id,
  }
  -- Genau dieselbe Uebersetzung wie in build_status_payload(): der lokale
  -- Schirm und die Telemetrie an MASTER zeigen denselben Regler, also
  -- duerfen sie nicht aus verschiedenen Quellen lesen.
  local v2 = rt2_engine.status_fields()
  monitor_ctx.capacity_override = {
    ready         = v2.capacity_ready == true,
    max_output    = v2.capacity_max or 0,
    at_target     = v2.capacity_at_target or 0,
    total_turbines = v2.capacity_total_turbines or 0,
    reason        = v2.capacity_reason or v2.capacity_source or "UNKNOWN",
    required_turbines = v2.capacity_required_turbines or 0,
  }
  monitor_ctx.node_state    = v2.node_state
  monitor_ctx.current_state = v2.mode
  -- Was der Regler je Turbine ZULETZT ENTSCHIEDEN hat, nach Peripheriename.
  --
  -- Die Turbinenliste des Schirms entsteht in monitor_ui.build_turbine_status()
  -- aus einem EIGENEN Leseweg (peripheral.wrap), voellig unabhaengig von der
  -- Regelkette. Das ist praktisch -- die Anzeige lebt auch dann, wenn ein
  -- Adapter klemmt -- hat aber einen Preis: steht die Regelung still, laufen
  -- Drehzahl und Durchfluss auf dem Schirm munter weiter, und von aussen ist
  -- nicht zu sehen, dass niemand mehr stellt. Genau so wurde auf node-102
  -- eine festhaengende Node stundenlang fuer gesund gehalten.
  --
  -- Der Grund der letzten Entscheidung schliesst diese Luecke: er sagt, was
  -- der Regler WILL, nicht was die Hardware gerade tut.
  local reasons = {}
  for _, t in ipairs(v2.turbines or {}) do
    if t.id then reasons[t.id] = t.flow_reason end
  end
  monitor_ctx.turbine_flow_reasons = reasons
  -- ctx.targets fuellt niemand mehr (handle_command_rt2 ist der einzige
  -- Command-Handler); die Vorgabe lebt im Orchestrator.
  local v2_targets = {}
  for k, val in pairs(ctx and ctx.targets or {}) do v2_targets[k] = val end
  v2_targets.power_percent = v2.master_percent or v2_targets.power_percent
  v2_targets.power         = v2.power_target or v2_targets.power
  -- Zieldrehzahl fuer die Anzeige: die hoechste, die dieser Takt
  -- irgendeiner Turbine gesetzt hat (Puffer-/Aus-Slots liegen darunter).
  local max_target_rpm = 0
  for _, t in ipairs(v2.turbines or {}) do
    local r = tonumber(t.target_rpm) or 0
    if r > max_target_rpm then max_target_rpm = r end
  end
  if max_target_rpm > 0 then v2_targets.rpm = max_target_rpm end
  monitor_ctx.targets       = v2_targets
  monitor_ctx.target_power   = v2_targets.power
  monitor_ctx.target_percent = v2_targets.power_percent
  last_status_snapshot = monitor_ui.update(mon, monitor_ctx)
end

-- ── Control-Tick ──────────────────────────────────────────────────────────────

local rt_update_quiescing = false
local rt_quiesce_hold_logged = false

-- Der einzige Regel-Einstiegspunkt der Node. Frueher standen hier v1s
-- Lebenszyklus und eine Zustandsmaschine, deren
-- on_tick-Handler die Regelung aufriefen; beides ist entfallen. rt2_engine
-- .tick() macht alles: lesen, entscheiden, schreiben, speichern.
local function control_tick()
  -- A dedicated safe-state writer owns the hardware from the first update
  -- quiesce attempt onward. Normal regulation must not race it.
  -- Diese Sperre war bis v768 eine Einbahnstrasse ohne Rueckweg: wurde ein
  -- Quiesce-Request storniert, statt in einen Reboot zu laufen, regelte die
  -- Node nie wieder -- unsichtbar, weil Anzeige und Drehzahl-Messung
  -- weiterliefen. Der Rueckweg ist jetzt update_quiesce_resume() (unten,
  -- verdrahtet als on_quiesce_cancelled). Damit dieser Zustand nicht noch
  -- einmal stumm bleibt, sagt er es einmal laut.
  if rt_update_quiescing then
    if not rt_quiesce_hold_logged then
      rt_quiesce_hold_logged = true
      log("WARN", "Regelung ausgesetzt: UPDATE_QUIESCE haelt die Hardware"
        .. " im sicheren Zustand (Flow 0, Coils eingehaengt, Rods 100%)")
      pcall(print, "[RT] REGELUNG AUSGESETZT -- UPDATE_QUIESCE aktiv")
    end
    return
  end
  rt2_engine.tick(ctx)
end

-- ── Command-Handler ───────────────────────────────────────────────────────────

local handle_command

local function handle_command_rt2(message)
  local network_id = comms and comms.network and comms.network.id or config.node_id
  if not protocol.is_for_node(message, network_id) then
    return
  end
  if not protocol.is_proto_compatible(message.proto_ver) then
    local result = { ok = false, error = "proto mismatch", reason_code = "PROTO_MISMATCH" }
    last_command, last_command_ts = result.error, os.epoch("utc")
    return result
  end
  local payload = type(message.payload) == "table" and message.payload or nil
  local command = payload and payload.command
  if type(command) ~= "table" then
    local result = { ok = false, error = "invalid command", reason_code = "INVALID_COMMAND" }
    last_command, last_command_ts = result.error, os.epoch("utc")
    return result
  end
  master_seen_ts = os.epoch("utc")
  rt2_engine.note_master_seen(master_seen_ts)
  -- master_seen_ts ist in dieser Zustellung gerade gesetzt worden -- mit
  -- derselben Uhrzeit kann der Kommando-Handler die MASTER-Verbindung
  -- bewerten, ohne auf den naechsten Regeltakt zu warten.
  local result = rt2_engine.handle_command(command, master_seen_ts)
  last_command, last_command_ts = (result.ok and "ok" or (result.error or "error")), os.epoch("utc")
  log(result.ok == false and "WARN" or "INFO", ("v2 command target=%s ok=%s%s"):format(
    tostring(command.target), tostring(result.ok),
    result.ok == false and (" error=" .. tostring(result.error) .. " reason=" .. tostring(result.reason_code)) or ""))
  -- module_id gehoert in die Quittung: MASTERs Startup-Sequencer ordnet das
  -- ACK ueber dieses Feld zu (siehe rt2_command_handler.lua's clear_trip).
  return { ok = result.ok, error = result.error, reason_code = result.reason_code,
           module_id = result.module_id }
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

  -- Die Regel-Engine. Es gibt nur noch diese eine; das frueher hier
  -- ausgewertete config.engine-Feld ist entfallen. Mehrere Reaktoren an
  -- einem Knoten sind
  -- unterstuetzt: sie speisen dasselbe Dampfnetz, und jeder regelt seine
  -- Staebe unabhaengig aus SEINEM eigenen Dampftank (rt2_unit.lua). Sie
  -- stimmen sich nicht ab und brauchen es auch nicht -- zieht die Flotte
  -- mehr, fallen alle Taenke, alle fahren die Staebe aus.
  rt2_engine.init({ turbine_count = #devices.turbines, config = config, log = log })
  log("INFO", string.format("Regler aktiv (%d Reaktor(en), %d Turbinen)",
    #devices.reactors, #devices.turbines))
  -- utils.log() routet standardmaessig zum Log-Collector, nicht auf den
  -- lokalen Bildschirm -- diese Zeile ist bewusst ein direktes print(),
  -- damit am Computer selbst sofort sichtbar ist, dass der Regler laeuft,
  -- ohne Router-UI oder Log-Collector zu brauchen.
  pcall(print, string.format("[RT] REGLER AKTIV -- %d Reaktor(en), %d Turbinen",
    #devices.reactors, #devices.turbines))

  -- Hardware-Zugriffs-State initialisieren (Capability-Cache, Rod-/Flow-
  -- Buchfuehrung fuer den Update-Quiesce -- keine Regelung)
  reactor_control.init_reactor_ctrl(ctx)
  turbine_control.init_turbine_ctrl(ctx)

  -- Initiale Rod-Stellung: voll eingefahren. Der Regler faehrt sie von da
  -- aus herunter, sobald der Dampftank Bedarf zeigt.
  reactor_control.apply_initial_reactor_rods(ctx)

  -- Services
  services = service_manager.new({ log_prefix = "RT" })
  slow_services = service_manager.new({ log_prefix = "RT-BG" })

  handle_command = handle_command_rt2

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
        rt2_engine.note_master_seen(master_seen_ts)
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

  slow_services:add(discovery_service.new({
    registry = registry,
    discover = discover_with_stability_tracking,
    should_discover = should_discover,
    interval = config.scan_interval or config.heartbeat_interval,
    managed_registry = false,
    update_health = function(ok) devices.discovery_failed = not ok end,
  }))

  -- Control-Service (Reaktor-/Turbinenregelung) bleibt in der "fast"-
  -- Coroutine (siehe run_fast_loop/run_slow_loop unten): zeitkritisch, darf
  -- nicht hinter Discovery/Telemetry in derselben Liste warten muessen.
  services:add({
    name = "control",
    tick = function() control_tick() end,
  })

  slow_services:add(telemetry_service.new({
    comms = comms,
    status_interval  = config.status_interval or config.heartbeat_interval,
    heartbeat_interval = config.heartbeat_interval,
    heartbeat_state  = function()
      return { state = rt2_engine.status_fields().node_state or "INIT" }
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
  slow_services:init()

  -- Monitor initialisieren
  local mon_entry = adapters.monitor.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  devices.monitor = mon_entry and mon_entry.mon or nil
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current()
  end
  monitor_ui.init(devices.monitor, config.monitor, config.monitor_scale)

  -- Monitor scale adjustable by touch on the diagnostics page: applies
  -- live and persists to config/rt.lua so it survives a reboot.
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
    -- config.role ist immer "RT-NODE" (siehe nodes/rt/config.lua), niemals "RT".
    checks[#checks + 1] = { name = "Rolle konfiguriert", ok = tostring(config.role or "") == "RT-NODE" }
    -- Speaker: optional, pcall da nicht immer installiert.
    local ok_spk, spk_mod = pcall(require, "optional.speaker_alarm")
    local speaker = ok_spk and spk_mod.new() or nil
    report_mod.run(checks, { log = log, speaker = speaker })
  end)

  log("INFO", "RT-Node ready: " .. (comms.network and comms.network.id or node_id))
end

-- ── Start ────────────────────────────────────────────────────────────────────

init()

-- discover() re-runs periodically via discovery_service (see services:add
-- above, interval = config.scan_interval) -- no separate fallback timer
-- needed here.

local quiesce_handshake = _G.__xreactor_update_handshake
local last_quiesce_warning = 0

local function update_quiesce_safe()
  rt_update_quiescing = true
  current_state_value = STATE.SAFE

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

-- Gegenstueck zu update_quiesce_safe(): core/update_handshake.lua's reset()
-- storniert einen Quiesce-Request ausdruecklich nur, solange die Rolle noch
-- laeuft (installer/auto_update.lua's recover_unexpected() tut genau das im
-- Zustand QUIESCE_REQUESTED -- ohne Reboot). Ohne diesen Rueckweg blieb die
-- Node danach fuer immer stehen: control_tick() kehrte sofort zurueck, also
-- regelte niemand mehr, waehrend auf allen Turbinen Flow 0 stand
-- und die Coils eingehaengt waren -- der Zustand, den update_quiesce_safe()
-- geschrieben hat, nicht einer, den ein Regler beschlossen haette. Nur ein
-- Reboot half. Der Reaktorzweig braucht keine Sonderbehandlung: der Regler
-- regelt die Staebe aus dem eigenen Dampftank, sobald er wieder tickt.
local function update_quiesce_resume()
  if not rt_update_quiescing then return end
  rt_update_quiescing = false
  rt_quiesce_hold_logged = false
  current_state_value = STATE.AUTONOM
  log("WARN", "UPDATE_QUIESCE zurueckgenommen -- Regelung laeuft wieder an")
  pcall(print, "[RT] UPDATE_QUIESCE zurueckgenommen -- Regelung laeuft wieder")
end

-- Zwei entkoppelte Coroutinen (siehe nodes/support/runtime.lua's run_fast_
-- loop()/run_slow_loop()): "fast" traegt UI/Touch/Comms UND die
-- zeitkritische Reaktor-/Turbinenregelung ("control"-Service), "slow"
-- traegt Discovery/Telemetry -- ein langsamer Discovery-Scan soll die
-- Regelung/UI nicht mehr blockieren.
local ok, result = xpcall(function()
  parallel.waitForAny(
    function()
      support_runtime.run_fast_loop({
        receive_timeout = CONFIG.RECEIVE_TIMEOUT, services = services, comms = comms,
        quiesce_opts = quiesce_handshake and {
          handshake = quiesce_handshake,
          on_quiesce = update_quiesce_safe,
          on_quiesce_cancelled = update_quiesce_resume,
        } or nil,
      })
    end,
    function()
      support_runtime.run_slow_loop({ interval = CONFIG.RECEIVE_TIMEOUT, services = slow_services })
    end
  )
end, function(e) return e end)
if not ok and not support_runtime.is_terminate(result) then
  support_runtime.crash_screen(result)
end
