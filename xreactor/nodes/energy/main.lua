-- nodes/energy/main.lua
-- Energy-Node Bootstrap und Orchestrierung.
-- Fachlogik in separaten Modulen:
--   heartbeat.lua  — Heartbeat-Thread (nie blockierend)
--   matrix.lua     — Matrix-Polling-Thread (darf blockieren)
--   discovery_runtime.lua — Peripheral-Discovery
--   status_payload.lua    — Telemetrie-Payload
--   command_handler.lua   — Eingehende Commands

local CONFIG = {
  LOG_NAME              = "energy",
  LOG_PREFIX            = "ENERGY",
  BOOTSTRAP_LOG_ENABLED = false,
  NODE_ID_PATH          = "/xreactor/config/node_id.txt",
  CONFIG_PATH           = "/xreactor/nodes/energy/config.lua",
  RECEIVE_TIMEOUT       = 0.5,
}

-- ── Bootstrap ────────────────────────────────────────────────────────────────
local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({ role = "energy", log_enabled = false })
local require = bootstrap.require

-- ── Requires ─────────────────────────────────────────────────────────────────
local constants              = require("shared.constants")
local utils                  = require("core.utils")
local health                 = require("core.health")
local ui                     = require("core.ui")
local ui_router              = require("core.ui_router")
local colors                 = require("shared.colors")
local registry_lib           = require("core.registry")
local storage_adapter        = require("adapters.energy_storage")
local matrix_adapter         = require("adapters.induction_matrix")
local monitor_adapter        = require("adapters.monitor")
local service_manager        = require("services.service_manager")
local comms_service          = require("services.comms_service")
local discovery_service      = require("services.discovery_service")
local telemetry_service      = require("services.telemetry_service")
local ui_service             = require("services.ui_service")
local matrix_sampling_service = require("services.matrix_sampling_service")
local discovery_log          = require("nodes.energy.discovery_log")
local matrix_snapshot_runtime = require("nodes.energy.matrix_snapshot_runtime")
local matrix_topology_cache  = require("nodes.energy.matrix_topology_cache")
local config_normalizer      = require("nodes.energy.config_normalizer")
local support_runtime        = require("nodes.support.runtime")
local message_handler_lib    = require("nodes.energy.command_handler")
local status_payload_runtime = require("nodes.energy.status_payload")
local ui_model_runtime       = require("nodes.energy.ui_model")
local energy_ui_pages        = require("nodes.energy.ui_pages")
local runtime_context        = require("nodes.energy.runtime_context")
local discovery_runtime      = require("nodes.energy.discovery_runtime")
local storage_snapshot_runtime = require("nodes.energy.storage_snapshot_runtime")
local role_logic             = require("nodes.support.role_logic")
-- Phase-2 Rewrite: neue Thread-Module
local heartbeat_mod          = require("nodes.energy.heartbeat")
local matrix_mod             = require("nodes.energy.matrix")

-- ── Config ───────────────────────────────────────────────────────────────────
local DEFAULT_CONFIG = {
  role = constants.roles.ENERGY_NODE, node_id = "ENERGY-1",
  debug_logging = true, reset_log_on_start = true,
  wireless_modem = nil, wired_modem = nil, matrix = nil,
  matrix_names = {}, matrix_aliases = {}, cubes = {},
  scan_interval = 2, discovery_force_rescan_interval = 300,
  matrix_metric_poll_interval = 3.0, matrix_metric_call_budget = 6,
  matrix_metric_time_budget_ms = 2000, matrix_metric_slow_call_ms = 400,
  matrix_metric_slow_poll_multiplier = 4.0, matrix_metric_per_matrix_budget = 1,
  matrix_sample_min_tick_spacing_ms = 400,
  matrix_component_poll_interval = 30, matrix_component_call_budget = 2,
  matrix_component_time_budget_ms = 2000,
  ui_refresh_interval = 1.0, ui_scale = 0.5,
  monitor = { preferred_name = nil, strategy = "largest" },
  storage_filters = { include_names = nil, exclude_names = {}, prefer_names = {} },
  heartbeat_interval = 2, status_interval = 5,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
  comms = {
    ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 45.0,
    peer_down_grace_s = 10.0, peer_down_min_observations = 3,
    peer_up_debounce_s = 3.0, peer_up_min_observations = 3,
    queue_limit = 200, drop_simulation = 0
  }
}

local config_warnings = {}
-- Fix (2026-07-13): CRITICAL (GLOBAL-P0, siehe docs/CODING_AI_OTHER_
-- NODES_PERFORMANCE_2026-07-12.md). Wie bei FUEL bereits behoben: die
-- urspruenglich hier hart codierte Quelldatei ist Teil des Manifests und
-- wird bei jedem Auto-Update ueberschrieben -- jede manuelle Config-
-- Bearbeitung ging dadurch spaetestens beim naechsten Update-Zyklus
-- verloren.
local ENERGY_SOURCE_CONFIG_PATH = CONFIG.CONFIG_PATH
local ENERGY_USER_CONFIG_PATH = "/xreactor/config/energy.lua"
if not fs.exists(ENERGY_USER_CONFIG_PATH) and fs.exists(ENERGY_SOURCE_CONFIG_PATH) then
  local ok_read, handle = pcall(fs.open, ENERGY_SOURCE_CONFIG_PATH, "r")
  if ok_read and handle then
    local content = handle.readAll()
    handle.close()
    local dir = fs.getDir(ENERGY_USER_CONFIG_PATH)
    if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
    local ok_write, out = pcall(fs.open, ENERGY_USER_CONFIG_PATH, "w")
    if ok_write and out then
      out.write(content)
      out.close()
      utils.log(CONFIG.LOG_PREFIX or "ENERGY", "Config-Migration: " .. ENERGY_SOURCE_CONFIG_PATH .. " -> " .. ENERGY_USER_CONFIG_PATH, "INFO")
    end
  end
end
CONFIG.CONFIG_PATH = ENERGY_USER_CONFIG_PATH
local config = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
config_normalizer.normalize(config, DEFAULT_CONFIG, utils, function(w) table.insert(config_warnings, w) end)

-- ── Logger ────────────────────────────────────────────────────────────────────
local node_id = utils.read_node_id(CONFIG.NODE_ID_PATH)
local log_name = utils.build_log_name(CONFIG.LOG_NAME, node_id)
utils.init_logger({ log_name = log_name, prefix = CONFIG.LOG_PREFIX,
  enabled = config.debug_logging, truncate = config.reset_log_on_start == true })
utils.log(CONFIG.LOG_PREFIX, "Startup", "INFO")
for _, w in ipairs(config_warnings) do utils.log(CONFIG.LOG_PREFIX, w, "WARN") end

local function log(msg, level) utils.log(CONFIG.LOG_PREFIX, msg, level or "INFO") end

-- ── State ─────────────────────────────────────────────────────────────────────
local registry = registry_lib.new({ node_id = node_id, role = "energy",
  log_prefix = CONFIG.LOG_PREFIX, aliases = config.matrix_aliases or {} })
local energy_health = health.new({})
local runtime = runtime_context.new({ config = config, role = "energy" })
local devices = runtime.devices
local ui_state = runtime.ui_state
local now_ms   = runtime.now_ms

-- Fix (2026-07-16): CRITICAL (ENERGY-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 13). "services" enthielt bisher ALLE
-- Services (COMMS/DISCOVERY/STORAGE_SAMPLE/MATRIX_SAMPLE/TELEMETRY/UI) und
-- wurde ausschliesslich aus dem Matrix-Thread (nodes/energy/matrix.lua)
-- heraus per services:tick() periodisch geticked -- ein langsamer Matrix-
-- Peripherie-Call (dokumentiert 1-4s) verzoegerte dadurch im selben
-- sequentiellen tick()-Aufruf auch COMMS/Discovery/Telemetry/UI, obwohl
-- der eigentliche Sinn der zwei getrennten Coroutinen (heartbeat.lua +
-- matrix.lua via parallel.waitForAny) genau das verhindern sollte.
-- Jetzt: "matrix_services" ist eine EIGENE, zweite service_manager-Instanz
-- nur fuer die beiden potenziell blockierenden Peripherie-Poll-Services
-- (STORAGE_SAMPLE/MATRIX_SAMPLE) -- ausschliesslich aus dem Matrix-Thread
-- geticked. "services" enthaelt nur noch COMMS/DISCOVERY/TELEMETRY/UI und
-- wird jetzt aus dem (nie blockierenden) Heartbeat-Thread periodisch
-- geticked (siehe heartbeat.lua), komplett entkoppelt von Matrix-Polling.
local comms, services, matrix_services, matrix_runtime, topology_cache
local status_payload_builder, ui_model_builder, ui_pages

-- Heartbeat-State (geteilt zwischen Threads)
local hb_state = { last_ts = 0, last_warn_ts = 0 }

local function heartbeat_interval_ms()
  return runtime_context.heartbeat_interval_ms(config)
end

local function send_heartbeat(ts)
  ts = ts or now_ms()
  local state = runtime_context.make_presence(config, comms, ts)
  comms:send_heartbeat(state)
  hb_state.last_ts = ts
end

-- Fix (2026-07-16): CRITICAL (ENERGY-P0). Einzige zentrale "sende
-- Heartbeat, falls faellig"-Quelle -- ersetzt die zuvor an drei Stellen
-- unabhaengig voneinander dupliziert Intervallpruefung (inter_service_hook
-- unten, matrix_runtime's heartbeat_pump-Option, und einen komplett
-- UNGEGATETEN Aufruf in matrix.lua, der bei jedem ~0.5s-Loop-Durchlauf
-- bedingungslos sendete -- deutlich mehr Heartbeats als konfiguriert).
local function send_heartbeat_if_due(now)
  now = now or now_ms()
  if (now - hb_state.last_ts) >= heartbeat_interval_ms() then
    send_heartbeat(now)
    return true
  end
  return false
end

-- Fix (2026-07-17): CRITICAL (ENERGY-P1, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 15). heartbeat.lua fuehrte bisher
-- eine EIGENE, private "last_heartbeat_ts"-Kopie im hb-Ctx (initialisiert
-- mit 0, unabhaengig von hb_state.last_ts), um seinen eigenen Timer- und
-- Modem-Event-Pfad zu gaten. Dieser Getter macht hb_state.last_ts (die
-- einzige, tatsaechlich geteilte Quelle, die auch send_heartbeat_if_due()
-- und damit der Matrix-Thread verwenden) fuer heartbeat.lua lesbar, ohne
-- eine zweite, driftende Kopie einzufuehren.
local function get_last_heartbeat_ts()
  return hb_state.last_ts
end

-- ── Handle Remote-Update Command ─────────────────────────────────────────────
local function handle_command(message)
  local payload = type(message) == "table" and message.payload or nil
  local command = payload and payload.command
  if type(command) == "table" and command.target == "REMOTE_UPDATE" then
    require("core.remote_update").handle_command({
      log_prefix = "ENERGY", utils = utils,
      send_ack = comms and function() comms:send_ack(message, true, { updating = true }) end or nil,
    })
    return { ok = true }
  end
  return { ok = false, error = "unsupported command", reason_code = "UNSUPPORTED_COMMAND" }
end

-- ── Matrix-Stats lesen (aus Snapshot) ────────────────────────────────────────
local function read_matrix_stats(opts)
  opts = opts or {}
  local max_age = tonumber(opts.max_age_ms) or math.max(3000, math.floor((tonumber(config.status_interval) or 5) * 1000))
  if not matrix_runtime then
    return { matrices = {}, total = { stored=0, capacity=0, percent=0 }, diag = {}, stale = true }
  end
  local snap = matrix_runtime:get_snapshot(max_age)
  return { matrices = snap.matrices or {}, total = snap.total or { stored=0, capacity=0, percent=0 },
    diag = snap.diag or {}, stale = snap.stale, freshness_ms = snap.freshness_ms }
end

-- ── Init ─────────────────────────────────────────────────────────────────────
local function init()
  log("Initializing...", "INFO")

  local msg_handler = message_handler_lib.new({
    constants = constants,
    mark_master_seen = function() runtime.master_seen_ts = os.epoch("utc") end,
    on_master_alerts = function(a) runtime.master_alerts = a end,
    on_proto_mismatch = function() devices.proto_mismatch = true end
  })

  comms = comms_service.new({
    name = "COMMS", config = config, log_prefix = "ENERGY",
    on_message = function(m) return msg_handler.handle_message(m) end,
    on_command = handle_command
  })

  -- Fix (2026-07-16): CRITICAL (ENERGY-P0). "services" tickt jetzt nur noch
  -- COMMS/DISCOVERY/TELEMETRY/UI, periodisch aus dem Heartbeat-Thread
  -- (siehe heartbeat.lua) -- kein inter_service_hook mehr noetig, da
  -- send_heartbeat_if_due() jetzt die alleinige, zentrale Heartbeat-Quelle
  -- ist (siehe oben).
  services = service_manager.new({ log_prefix = "ENERGY" })
  -- Zweite, unabhaengige Service-Gruppe nur fuer die beiden potenziell
  -- blockierenden Peripherie-Poll-Services (STORAGE_SAMPLE/MATRIX_SAMPLE,
  -- siehe services:add() weiter unten) -- ausschliesslich aus dem Matrix-
  -- Thread geticked, komplett getrennt von COMMS/DISCOVERY/TELEMETRY/UI.
  matrix_services = service_manager.new({ log_prefix = "ENERGY_MATRIX" })

  matrix_runtime = matrix_snapshot_runtime.new({
    log_prefix = "ENERGY", config = config, debug_enabled = config.debug_logging,
    get_groups = function() return devices.matrix_groups or {} end,
    -- Fix (2026-07-13): CRITICAL (ENERGY-P0, siehe docs/CODING_AI_OTHER_
    -- NODES_PERFORMANCE_2026-07-12.md). heartbeat_pump() rief send_
    -- heartbeat() bisher UNGEFILTERT bei jedem Matrix-Sample-Zyklus auf
    -- (~alle 0.5s), unabhaengig vom eigentlich konfigurierten Heartbeat-
    -- Intervall (Standard 2s) -- ein Heartbeat-Ziel muss nur SOOFT wie
    -- konfiguriert bedient werden, nicht bei jeder Gelegenheit, bei der
    -- der Aufrufer gerade "vorbeikommt".
    -- Fix (2026-07-16): CRITICAL (ENERGY-P0, Abschnitt 13). Nutzt jetzt die
    -- zentrale send_heartbeat_if_due()-Quelle statt einer eigenen, dritten
    -- Kopie derselben Intervallpruefung.
    heartbeat_pump = function()
      send_heartbeat_if_due(now_ms())
    end,
    record_error = function(scope, err)
      devices.last_error = tostring(scope) .. ": " .. tostring(err)
    end
  })

  topology_cache = matrix_topology_cache.new({
    log_prefix = "ENERGY", forced_rescan_interval_s = config.discovery_force_rescan_interval
  })

  local storage_runtime = storage_snapshot_runtime.new({
    now_ms = now_ms, config = config, devices = devices, utils = utils,
    record_error = function(scope, err) devices.last_error = tostring(scope) .. ": " .. tostring(err) end
  })

  local discovery_runner = discovery_runtime.new({
    config = config, debug_enabled = config.debug_logging, utils = utils,
    peripheral = peripheral, monitor_adapter = monitor_adapter,
    matrix_adapter = matrix_adapter, storage_adapter = storage_adapter,
    discovery_log = discovery_log, registry = registry, devices = devices,
    topology_cache = topology_cache, matrix_runtime = matrix_runtime,
    record_error = function(scope, err) devices.last_error = tostring(scope) .. ": " .. tostring(err) end,
    on_topology_changed = function()
      runtime.status_payload_cache.ts = 0; runtime.status_payload_cache.payload = nil
      runtime.ui_model_cache.ts = 0; runtime.ui_model_cache.model = nil; runtime.ui_model_cache.key = nil
    end,
    log = log
  })

  status_payload_builder = status_payload_runtime.new({
    now_ms = now_ms, config = config, utils = utils, health = health,
    registry = registry, devices = devices, energy_health = energy_health,
    read_storage_stats = storage_runtime.read_storage_stats,
    read_matrix_stats = read_matrix_stats,
    is_master_connected = function()
      return role_logic.is_master_connected({
        comms = comms, master_role = constants.roles.MASTER,
        last_seen_ts = runtime.master_seen_ts, heartbeat_interval = config.heartbeat_interval
      })
    end,
    status_payload_cache = runtime.status_payload_cache,
    log = log
  })

  ui_pages = energy_ui_pages.new({ ui = ui, colors = colors, ui_router = ui_router,
    ui_state = ui_state, utils = utils })

  ui_model_builder = ui_model_runtime.new({
    now_ms = now_ms, config = config, utils = utils, health = health,
    registry = registry, comms = comms, devices = devices,
    master_peer_state = function() return role_logic.master_peer_state(comms, constants.roles.MASTER) end,
    master_alerts = function() return runtime.master_alerts end,
    build_status_payload = function(a) return status_payload_builder.build_status_payload(a) end,
    ui_model_cache = runtime.ui_model_cache
  })

  -- Services registrieren
  services:add(comms)
  services:add(discovery_service.new({
    name = "DISCOVERY", log_prefix = "DISCOVERY", registry = registry,
    discover = discovery_runner.discover, interval = config.scan_interval,
    should_discover = function(_, ts, event, due)
      return topology_cache and topology_cache:should_discover(ts, event, due) or due
    end,
    managed_registry = false,
    update_health = function(ok) devices.discovery_failed = not ok end
  }))
  -- Fix (2026-07-16): CRITICAL (ENERGY-P0, siehe docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md Abschnitt 13). STORAGE_SAMPLE/MATRIX_SAMPLE
  -- laufen jetzt in matrix_services (eigene, nur aus dem Matrix-Thread
  -- geticke Gruppe), NICHT mehr in "services" (COMMS/DISCOVERY/TELEMETRY/
  -- UI, aus dem Heartbeat-Thread geticke) -- ein langsamer Peripherie-Call
  -- in einem der beiden Sample-Services verzoegert dadurch nicht mehr
  -- COMMS/Discovery/Telemetry/UI im selben sequentiellen tick()-Aufruf.
  matrix_services:add(matrix_sampling_service.new({
    name = "STORAGE_SAMPLE", interval = 0.5, start_delay = 0.10,
    runtime = { tick = function(_, ts) storage_runtime.sample_storage_stats(ts or now_ms()) end }
  }))
  matrix_services:add(matrix_sampling_service.new({
    name = "MATRIX_SAMPLE", interval = 0.75, start_delay = 0.20,
    runtime = matrix_runtime
  }))
  local status_interval_ms = math.max(1000, math.floor((tonumber(config.status_interval) or 5) * 1000))
  services:add(telemetry_service.new({
    name = "TELEMETRY", log_prefix = "TELEMETRY", comms = comms,
    status_interval = config.status_interval or config.heartbeat_interval,
    heartbeat_interval = config.heartbeat_interval, enable_heartbeat = false,
    status_max_age_ms = math.floor(status_interval_ms * 0.9),
    build_payload = function(o) return status_payload_builder.build_status_payload(o) end
  }))
  services:add(ui_service.new({
    name = "UI", interval = config.ui_refresh_interval,
    snapshot = function()
      local model = ui_model_builder.build_ui_model({
        max_age_ms = math.max(1000, math.floor((tonumber(config.status_interval) or 5) * 1000))
      })
      ui_state.model = model
      local pages = {
        -- Fix (2026-07-06): diese Wrapper gaben den Rueckgabewert von
        -- ui_pages.render_xxx() (die footer_nav()-Touch-Koordinaten fuer
        -- ZURUECK/WEITER) bisher nicht zurueck — der Router bekam immer
        -- nil und konnte seine Touch-Zonen nie auf die sichtbaren Buttons
        -- legen. Derselbe Bug wie zuvor bei RT (dort direkt behoben durch
        -- return-Statements in mockup_pages.lua selbst), hier zusaetzlich
        -- durch diese anonyme Wrapper-Schicht verursacht.
        { name = "Overview",     render = function(t, v) return ui_pages.render_overview(t, v.data or v) end },
        { name = "Matrices",     render = function(t, v) return ui_pages.render_matrices(t, v.data or v) end },
      }
      if #(model.storages or {}) > 0 then
        table.insert(pages, { name = "Storages", render = function(t, v) return ui_pages.render_storages(t, v.data or v) end })
      end
      table.insert(pages, { name = "Diagnostics", render = function(t, v) return ui_pages.render_diagnostics(t, v.data or v) end })
      if not ui_state.router or ui_state.router:count() ~= #pages then
        ui_state.router = ui_router.new(devices.monitor, {
          title = "ENERGY", pages = pages, interval = config.ui_refresh_interval,
          key_prev = { [keys.left] = true, [keys.pageUp] = true },
          key_next = { [keys.right] = true, [keys.pageDown] = true }
        })
      end
      return { page = ui_state.router and ui_state.router.index or 1, data = model }
    end,
    render = function()
      if not devices.monitor then return end
      local model = ui_state.model or ui_model_builder.build_ui_model({ max_age_ms = 5000 })
      if ui_state.router then
        ui_state.router:render(devices.monitor, { data = model })
      end
      -- Ampel-Statusmonitor: komplett fehlerisoliert, kann den Hauptmonitor
      -- oberhalb nicht beeinflussen selbst wenn render_ampel intern scheitert.
      pcall(function()
        if type(ui_pages.render_ampel) == "function" then
          ui_pages.render_ampel(devices.monitor_name, model)
        end
      end)
    end,
    handle_input = function(event)
      if ui_state.router then ui_state.router:handle_input(event) end
    end
  }))

  services:init()
  matrix_services:init()
  storage_runtime.sample_storage_stats(now_ms())

  local summary = registry:get_summary()
  comms:send_hello({
    storages = summary.kinds.storage and summary.kinds.storage.bound or 0,
    matrices  = summary.kinds.matrix  and summary.kinds.matrix.bound  or 0,
    monitor   = devices.monitor and 1 or 0
  })

  -- Startup-Diagnose-Report (Kernfunktion, 2026-07-01): siehe
  -- xreactor/core/startup_report.lua.
  local report_mod = require("core.startup_report")
  pcall(function()
    local checks = { report_mod.check_wireless_modem() }
    local kinds = summary.kinds or {}
    local matrices = kinds.matrix or {}
    local storages = kinds.storage or {}
    checks[#checks + 1] = { name = "Matrix/Storage erkannt", ok = (matrices.bound or 0) > 0 or (storages.bound or 0) > 0,
      detail = string.format("matrix=%d storage=%d", matrices.bound or 0, storages.bound or 0) }
    checks[#checks + 1] = { name = "Monitor gefunden", ok = devices.monitor ~= nil }
    local ok_spk, spk_mod = pcall(require, "optional.speaker_alarm")
    local speaker = ok_spk and spk_mod.new() or nil
    report_mod.run(checks, { log = log, speaker = speaker })
  end)

  log("Node ready: " .. comms.network.id)
end

-- ── Main ─────────────────────────────────────────────────────────────────────
local function shutdown(reason)
  log("Shutdown: " .. tostring(reason or "requested"), "WARN")
  if services then pcall(function() services:stop() end) end
  log("Shutdown complete")
end

local function is_terminate(err)
  return tostring(err or ""):lower():find("terminate", 1, true) ~= nil
end

-- Heartbeat-Context für heartbeat.lua
-- Fix (2026-07-16): CRITICAL (ENERGY-P0). services = die "schnelle" Gruppe
-- (COMMS/DISCOVERY/TELEMETRY/UI) -- heartbeat.lua tickt sie jetzt
-- periodisch (siehe dort, tick_interval_s), zusaetzlich zum bisherigen
-- Event-getriebenen Weiterreichen (monitor_touch/mouse_click/key).
local function make_hb_ctx()
  return {
    comms = comms, config = config, devices = devices,
    ui_state = ui_state, ui_pages = ui_pages, services = services,
    now_ms = now_ms, log = log,
    last_heartbeat_warn_ts = 0,
    heartbeat_interval_ms = heartbeat_interval_ms,
    send_heartbeat_if_due = send_heartbeat_if_due,
    get_last_heartbeat_ts = get_last_heartbeat_ts,
    tick_interval_s = CONFIG.RECEIVE_TIMEOUT,
  }
end

-- Matrix-Context für matrix.lua
-- Fix (2026-07-16): CRITICAL (ENERGY-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 13). services = jetzt matrix_
-- services (NUR STORAGE_SAMPLE/MATRIX_SAMPLE, siehe oben) statt der
-- vollstaendigen Service-Liste -- "Matrix-Thread tickt ausschliesslich
-- einen dedizierten Matrixservice". send_heartbeat_if_due statt des rohen,
-- ungegateten send_heartbeat -- war zuvor die Quelle der ungefilterten
-- Heartbeat-Flut (jeder ~0.5s-Loop-Durchlauf sendete bedingungslos).
local function make_mx_ctx()
  return {
    services = matrix_services, now_ms = now_ms,
    receive_timeout_s = CONFIG.RECEIVE_TIMEOUT,
    send_heartbeat_if_due = send_heartbeat_if_due, log = log,
  }
end

local ok, result = xpcall(function()
  init()
  send_heartbeat(now_ms())
  log("Entering parallel event loop (heartbeat + matrix threads)", "INFO")
  parallel.waitForAny(
    function() heartbeat_mod.run(make_hb_ctx()) end,
    function() matrix_mod.run(make_mx_ctx()) end
  )
  return "loop ended"
end, function(err) return err end)

if ok then
  shutdown(result)
elseif is_terminate(result) then
  shutdown("terminate received")
else
  shutdown("runtime error: " .. tostring(result))
  -- Fix (2026-07-13): CRITICAL (SHARED-P0.2, siehe docs/CODING_AI_OTHER_
  -- NODES_PERFORMANCE_2026-07-12.md). Vorher eigener, dupliziertes
  -- Crash-Handling hier, das UNBEGRENZT auf einen physischen Tastendruck
  -- wartete (pcall(os.pullEvent,"key")), bevor ueberhaupt rebootet wurde
  -- -- ohne physische Anwesenheit blieb ENERGY bei einem Fehler fuer
  -- immer haengen. Jetzt: dieselbe bereits fuer FUEL/WATER/REPROCESSOR/
  -- RT/LOG_COLLECTOR bewaehrte Logik (begrenzte Wartezeit, automatischer
  -- Reboot, Crash-Loop-Erkennung) wiederverwendet statt dupliziert.
  support_runtime.crash_screen("runtime error: " .. tostring(result))
end
