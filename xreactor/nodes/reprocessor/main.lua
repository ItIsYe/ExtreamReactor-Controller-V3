local CONFIG = {
  LOG_NAME = "reprocessor",
  LOG_PREFIX = "REPROC",
  DEBUG_LOG_ENABLED = nil,
  BOOTSTRAP_LOG_ENABLED = false,
  BOOTSTRAP_LOG_PATH = nil,
  NODE_ID_PATH = "/xreactor/config/node_id.txt",
  CONFIG_PATH = nil,
  RECEIVE_TIMEOUT = 0.5
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({ role = "reprocessor", log_enabled = false, log_path = nil })
local require = bootstrap.require
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local health = require("core.health")
local ui = require("core.ui")
local ui_router = require("core.ui_router")
local colors = require("shared.colors")
local registry_lib = require("core.registry")
local monitor_adapter = require("adapters.monitor")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local telemetry_service = require("services.telemetry_service")
local discovery_service = require("services.discovery_service")
local discovery_stability = require("core.discovery_stability")
local ui_service = require("services.ui_service")
local non_rt_payload = require("core.non_rt_payload")
local support_discovery = require("nodes.support.discovery")
local support_runtime = require("nodes.support.runtime")
local role_logic = require("nodes.support.role_logic")
local support_ui_pages = require("nodes.support.ui_pages")
local support_command_handler = require("nodes.support.command_handler")
local role_descriptor = require("nodes.reprocessor.role_descriptor")
local config_normalizer = require("nodes.reprocessor.config_normalizer")
local redstone_router_lib = require("nodes.fuel.redstone_router")
local router_ui_lib = require("nodes.fuel.router_ui")
local feed_router_lib = require("nodes.reprocessor.feed_router")
local reproc_ui_pages = require("nodes.reprocessor.ui_pages")

local DEFAULT_CONFIG = {
  role = constants.roles.REPROCESSOR_NODE,
  node_id = "REPROC-1",
  debug_logging = false,
  reset_log_on_start = true,
  wireless_modem = nil,
  wired_modem = nil,
  buffers = { "chemical_tank_0" },
  heartbeat_interval = 2,
  discovery_interval = 15,
  status_interval = 5,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
  comms = {
    ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0
  }
}

-- Die Quelldatei ist Teil des Manifests und wird bei jedem Auto-Update
-- ueberschrieben -- Config muss in eine geschuetzte Nutzerdatei migriert
-- werden, sonst geht jede manuelle Bearbeitung beim naechsten Update verloren.
local REPROC_USER_CONFIG_PATH = "/xreactor/config/reprocessor.lua"
if not fs.exists(REPROC_USER_CONFIG_PATH) and fs.exists(role_descriptor.config_path) then
  local ok_read, handle = pcall(fs.open, role_descriptor.config_path, "r")
  if ok_read and handle then
    local content = handle.readAll()
    handle.close()
    local dir = fs.getDir(REPROC_USER_CONFIG_PATH)
    if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
    local ok_write, out = pcall(fs.open, REPROC_USER_CONFIG_PATH, "w")
    if ok_write and out then
      out.write(content)
      out.close()
      utils.log(CONFIG.LOG_PREFIX or "REPROC", "Config-Migration: " .. role_descriptor.config_path .. " -> " .. REPROC_USER_CONFIG_PATH, "INFO")
    end
  end
end
CONFIG.CONFIG_PATH = REPROC_USER_CONFIG_PATH
local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}
local function add_config_warning(message) table.insert(config_warnings, message) end
config_normalizer.normalize(config, DEFAULT_CONFIG, add_config_warning, utils)

-- /xreactor/config/reproc_routes.lua (die vom Router-Editor geschriebene
-- kanonische Routenquelle) muss beim Start geladen werden, sonst gehen
-- gespeicherte Routen bei jedem Neustart verloren.
local routing_load_status = { ok = true, source = "config" }
do
  local routes_path = "/xreactor/config/reproc_routes.lua"
  if fs.exists(routes_path) then
    local ok_load, content = pcall(dofile, routes_path)
    if not ok_load or type(content) ~= "table" then
      routing_load_status = { ok = false, code = "ROUTES_FILE_UNREADABLE", message = tostring(content), source = routes_path }
      add_config_warning("reproc_routes.lua konnte nicht geladen werden, Routing bleibt INVALID: " .. tostring(content))
    else
      local validation = redstone_router_lib.validate_tree(content)
      if not validation.ok then
        local fe = validation.errors[1]
        routing_load_status = { ok = false, code = fe and fe.code or "INVALID", message = fe and fe.message or "Validierung fehlgeschlagen", source = routes_path }
        add_config_warning("reproc_routes.lua ungueltig, Routing bleibt INVALID: " .. tostring(routing_load_status.message))
      else
        config.feed = config.feed or {}
        config.feed.redstone_tree = content
        routing_load_status = { ok = true, source = routes_path }
      end
    end
  end
end

local node_id = support_runtime.init_logging({
  utils = utils, config = config, runtime_config = CONFIG,
  config_meta = config_meta, config_warnings = config_warnings
})

local comms
local services
local registry = registry_lib.new({ node_id = node_id, role = role_descriptor.role_key, log_prefix = CONFIG.LOG_PREFIX })
local reproc_health = health.new({})
local buffers = {}
local router
local rs_router
local router_ui_instance
local devices = {
  monitor = nil, monitor_name = nil, discovery_failed = false, registry_summary = nil,
  registry_load_error = nil, proto_mismatch = false, last_scan_ts = nil,
  last_command = nil, last_command_ts = nil
}
local master_alerts = {}
local master_seen = os.epoch("utc")
local standby = false
local monitor_router = nil
local current_mon = nil
local process_state = {}
local get_feed_router
local reproc_ui = reproc_ui_pages.new({ ui = ui, colors = colors, support_ui_pages = support_ui_pages, utils = utils, config = config, devices = devices })

local function warn_once(key, message)
  support_runtime.warn_once(devices, function(msg, level) utils.log(CONFIG.LOG_PREFIX, msg, level) end, key, message)
end

local function master_peer_state() return role_logic.master_peer_state(comms, constants.roles.MASTER) end
local function is_master_connected()
  return role_logic.is_master_connected({ comms = comms, master_role = constants.roles.MASTER, last_seen_ts = master_seen, heartbeat_interval = config.heartbeat_interval })
end

local function cache(bound_names) buffers = utils.cache_peripherals(bound_names or {}) end

local function discover()
  local names
  local registry_devices
  local allow_set = {}
  for _, name in ipairs(config.buffers or {}) do allow_set[name] = true end
  local allow_all = #config.buffers == 0
  local monitor_entry = monitor_adapter.find(nil, "largest", 0.5, CONFIG.LOG_PREFIX)
  local monitor_name = monitor_entry and monitor_entry.name or nil
  devices.monitor = monitor_entry and monitor_entry.mon or nil
  devices.monitor_name = monitor_name
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current(); devices.monitor_name = devices.monitor_name or "term"; devices.monitor_is_term = true
  end
  registry_devices, names = support_discovery.collect_monitor_device(utils, monitor_name)
  local buffer_devices = support_discovery.collect_devices_by_methods(names, {
    kind = "buffer",
    allow_name = function(name) return allow_all or allow_set[name] end,
    match = function(method_set) return (method_set.list and method_set.size) or method_set.getWaste or method_set.getItemCount end
  })
  for _, entry in ipairs(buffer_devices) do table.insert(registry_devices, entry) end
  registry:sync(registry_devices)
  devices.registry_summary = registry:get_summary()
  devices.registry_load_error = registry.state.load_error
  devices.last_scan_ts = os.epoch("utc")
  local bound = registry:get_bound_devices("buffer")
  local bound_names = {}
  for _, entry in ipairs(bound) do table.insert(bound_names, entry.name) end
  cache(bound_names)
end

local function hello()
  local summary = registry:get_summary()
  comms:send_hello({ buffers = summary.kinds.buffer and summary.kinds.buffer.bound or 0 })
end

local function read_buffer_capacity(buf)
  if buf.size then local ok, value = support_runtime.safe_wrapped_call(buf, "size"); if ok and type(value) == "number" then return value end end
  if buf.getSize then local ok, value = support_runtime.safe_wrapped_call(buf, "getSize"); if ok and type(value) == "number" then return value end end
  if buf.getCapacity then local ok, value = support_runtime.safe_wrapped_call(buf, "getCapacity"); if ok and type(value) == "number" then return value end end
  if buf.getMaxWaste then local ok, value = support_runtime.safe_wrapped_call(buf, "getMaxWaste"); if ok and type(value) == "number" then return value end end
  return nil
end

local function read_buffers()
  local info = {}
  for name, buf in pairs(buffers) do
    local stored = 0
    if buf.list and buf.size then
      local ok, items = support_runtime.safe_wrapped_call(buf, "list")
      if ok and type(items) == "table" then
        for _, stack in pairs(items) do if type(stack) == "table" and type(stack.count) == "number" then stored = stored + stack.count end end
      elseif not ok then warn_once("buffer_read:" .. tostring(name), "Buffer read failed for " .. tostring(name) .. ": " .. tostring(items)) end
    elseif buf.getWaste then
      local ok, value = support_runtime.safe_wrapped_call(buf, "getWaste")
      if ok and type(value) == "number" then stored = value
      elseif not ok then warn_once("buffer_read:" .. tostring(name), "Buffer read failed for " .. tostring(name) .. ": " .. tostring(value)) end
    elseif buf.getItemCount then
      local ok, value = support_runtime.safe_wrapped_call(buf, "getItemCount")
      if ok and type(value) == "number" then stored = value
      elseif not ok then warn_once("buffer_read:" .. tostring(name), "Buffer read failed for " .. tostring(name) .. ": " .. tostring(value)) end
    end
    local capacity = read_buffer_capacity(buf)
    local percent = (capacity and capacity > 0) and math.floor(stored / capacity * 1000 + 0.5) / 10 or nil
    table.insert(info, { id = name, stored = stored, capacity = capacity, percent = percent })
  end
  return info
end

local function build_status_payload_uncached()
  local reasons = {}
  if not next(buffers) then reasons[health.reasons.NO_STORAGE] = true end
  if devices.discovery_failed or devices.registry_load_error then reasons[health.reasons.DISCOVERY_FAILED] = true end
  if devices.proto_mismatch then reasons[health.reasons.PROTO_MISMATCH] = true end
  local master_ok = is_master_connected()
  if not master_ok then reasons[health.reasons.COMMS_DOWN] = true end
  reproc_health.status = next(reasons) and health.status.DEGRADED or health.status.OK
  reproc_health.reasons = reasons
  reproc_health.last_seen_ts = os.epoch("utc")
  -- Einmal gelesen, Ergebnis fuer Anzahl UND Inhalt wiederverwendet.
  local buffers_snapshot = read_buffers()
  reproc_health.bindings = { buffers = #buffers_snapshot }
  reproc_health.capabilities = { buffers = #config.buffers }
  local payload = non_rt_payload.build_base({
    ts = os.epoch("utc"), role = config.role, node_id = config.node_id,
    health = { status = reproc_health.status, reasons = health.reasons_list(reproc_health), last_seen_ts = reproc_health.last_seen_ts, bindings = reproc_health.bindings, capabilities = reproc_health.capabilities },
    discovery_failed = devices.discovery_failed, master_connected = master_ok,
    master_seen_s = master_seen and math.max(0, math.floor((os.epoch("utc") - master_seen) / 1000)) or nil,
    queue = comms and comms:get_diagnostics().queue_depth or 0,
    peers = comms and comms.peer_state and comms.peer_state.peers or nil,
    alerts = master_alerts, protocol_mismatch = devices.proto_mismatch,
    last_command = devices.last_command, last_command_ts = devices.last_command_ts,
    registry = { summary = devices.registry_summary or registry:get_summary(), devices = registry:get_devices_by_kind(), diagnostics = registry:get_diagnostics() }
  })
  payload.buffers = buffers_snapshot
  for _, entry in ipairs(payload.buffers) do entry.process_state = process_state[entry.id] end
  payload.standby = standby
  payload.feed = get_feed_router():get_summary()
  payload.bindings = reproc_health.bindings
  payload.bindings_summary = health.summarize_bindings(reproc_health.bindings)
  return payload
end

-- Kurzes TTL-Caching (wie bei FUEL): innerhalb von 300ms wird derselbe
-- bereits gebaute Payload fuer render_monitor()/ui_service-Snapshot/
-- Telemetrie wiederverwendet, statt ihn pro Konsument neu aufzubauen.
local payload_cache, payload_cache_ts = nil, 0
local PAYLOAD_CACHE_TTL_MS = 300
local function build_status_payload()
  local now = os.epoch("utc")
  if payload_cache and (now - payload_cache_ts) < PAYLOAD_CACHE_TTL_MS then
    return payload_cache
  end
  payload_cache = build_status_payload_uncached()
  payload_cache_ts = now
  return payload_cache
end

local function render_monitor()
  if not devices.monitor then return end
  local mon = devices.monitor
  current_mon = mon
  local payload = build_status_payload()
  local comms_diag = comms and comms:get_diagnostics() or {}
  local peer = master_peer_state()
  local summary = payload.registry and payload.registry.summary or registry:get_summary()
  local now = os.epoch("utc")
  local current_node_id = comms and comms.network and comms.network.id or config.node_id
  local alert_payload = master_alerts and master_alerts.by_node and master_alerts.by_node[current_node_id] or nil
  local model = support_ui_pages.build_common_model({
    payload = payload, summary = summary, comms_diag = comms_diag, master_peer = peer, now = now,
    last_scan_ts = devices.last_scan_ts, last_command = devices.last_command, last_command_ts = devices.last_command_ts,
    local_alerts = alert_payload and alert_payload.top or {}, local_alerts_critical = alert_payload and alert_payload.critical or 0,
    node_id = current_node_id
  })
  -- Seiten-Closures duerfen das Model NICHT vom ersten Aufbau einfrieren --
  -- muessen das frische model-Argument von router:render(mon, model) nutzen.
  if not monitor_router then
    monitor_router = ui_router.new({
      error_title = "REPROC UI ERROR",
      pages = {
        { name = "Overview", render = reproc_ui.render_overview },
        { name = "Details", render = reproc_ui.render_details },
        { name = "Diagnostics", render = reproc_ui.render_diagnostics,
          handle_touch = function(x, y) return reproc_ui.handle_diagnostics_touch(current_mon, x, y) end },
        -- Muss den Rueckgabewert von render() durchreichen (identisch zu
        -- nodes/fuel/monitor_ui.lua) -- sonst zeichnet ui_router.lua seinen
        -- eigenen generischen Page-Indikator ueber router_ui.lua's echten
        -- ZURUECK/WEITER-Buttons, deren Tap dann ins Leere liefe.
        { name = "Router", render = function(target, m, should_clear) return get_router_ui():render(target, ui, colors, should_clear) end,
          handle_touch = function(x, y) return get_router_ui():handle_touch(x, y) end }
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true }
    })
  end
  monitor_router:render(mon, model)
end

-- Zentraler, einziger Input-Pfad -- konsumierte Navigation stoppt die Weitergabe.
local function handle_monitor_touch(event)
  if monitor_router and monitor_router:handle_input(event) then
    return true
  end
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then
    local x, y = event and event[3], event and event[4]
    return page.handle_touch(x, y) == true
  end
  return false
end

-- Round-Robin-Cursor ueber eine deterministisch sortierte Namensliste:
-- hoechstens PROCESS_BUDGET_PER_CYCLE Buffer werden pro Aufruf verarbeitet
-- (der Rest kommt naechsten Zyklus dran), statt unbudgetiert alle Buffer
-- pro Zyklus zu durchlaufen. Backoff fuer durchgehend fehlschlagende Ports:
-- nach mehreren Fehlschlaegen werden mehrere Zyklen uebersprungen, statt
-- einen bekannt defekten Port jeden Zyklus erneut anzusprechen.
local PROCESS_BUDGET_PER_CYCLE = 4
local PROCESS_BACKOFF_THRESHOLD = 4
local PROCESS_BACKOFF_SKIP_CYCLES = 8
local process_cursor = 1
local process_fail_count = {}
local process_skip_remaining = {}

local function process_buffers()
  if standby then return end
  local names = {}
  for name in pairs(buffers) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then return end

  local processed_this_cycle = 0
  local attempts = 0
  while processed_this_cycle < PROCESS_BUDGET_PER_CYCLE and attempts < #names do
    attempts = attempts + 1
    if process_cursor > #names then process_cursor = 1 end
    local name = names[process_cursor]
    process_cursor = process_cursor + 1
    local buf = buffers[name]
    if not buf.process then
      if process_state[name] ~= "unsupported" then warn_once("no_process:" .. tostring(name), "Buffer " .. tostring(name) .. " has no process() method — not a reprocessor port") end
      process_state[name] = "unsupported"
    elseif (process_skip_remaining[name] or 0) > 0 then
      process_skip_remaining[name] = process_skip_remaining[name] - 1
    else
      processed_this_cycle = processed_this_cycle + 1
      local ok, err = pcall(buf.process)
      local prev = process_state[name]
      if ok then
        if prev ~= "ok" then utils.log("REPROC", "process() OK for " .. tostring(name)) end
        process_state[name] = "ok"
        process_fail_count[name] = 0
      else
        if prev ~= "error" then utils.log("REPROC", "process() failed for " .. tostring(name) .. ": " .. tostring(err), "WARN") end
        process_state[name] = "error"
        process_fail_count[name] = (process_fail_count[name] or 0) + 1
        if process_fail_count[name] >= PROCESS_BACKOFF_THRESHOLD then
          process_skip_remaining[name] = PROCESS_BACKOFF_SKIP_CYCLES
        end
      end
    end
  end
end

local function get_rs_router()
  if not rs_router then
    -- config.feed (nicht die Root-Config) uebergeben, da REPROCESSOR seine
    -- Route unter config.feed.redstone_tree definiert, nicht unter
    -- config.logistics.redstone_tree/config.redstone_tree wie FUEL.
    -- comms=comms ist noetig, damit refresh()'s self.comms:get_peers()
    -- einen konfigurierten Integrator als erreichbaren Wireless-VALVE-Node
    -- erkennen kann. get_rs_router() ist ein Lazy-Singleton -- "comms" ist
    -- zur Laufzeit als Upvalue bereits gesetzt.
    rs_router = redstone_router_lib.new({ config = config.feed or {}, node_id = node_id, log = function(level, msg) utils.log("REPROC", msg, level) end, warn_once = function(key, msg) warn_once(key, msg) end, comms = comms })
  end
  return rs_router
end

get_feed_router = function()
  if not router then
    router = feed_router_lib.new({ config = config, log = function(level, msg) utils.log("REPROC", msg, level) end, warn_once = function(key, msg) warn_once(key, msg) end, rs_router = get_rs_router() })
  end
  return router
end

-- Bricht eine laufende Transaktion beim UEBERGANG in den Standby sofort ab
-- (feed_router:cancel() -> redstone_router:shutdown_now(), blockiert alle
-- Ventile) statt sie durchlaufen zu lassen -- sonst koennte eine Transaktion
-- in WAIT_SETTLE/HOLD_OPEN trotz frisch eingetretenem Standby noch den
-- Exportcallback ausfuehren. Nur beim tatsaechlichen Uebergang false->true
-- aktiv (kein wiederholter shutdown_now() jeden Tick im Standby).
local function enter_standby(reason)
  if standby then return end
  standby = true
  get_feed_router():cancel(reason)
  utils.log("REPROC", "Standby aktiviert (" .. tostring(reason) .. ") -- laufende Ventil-Transaktion abgebrochen, alle Ventile blockiert", "WARN")
end

local function get_router_ui()
  if not router_ui_instance then
    router_ui_instance = router_ui_lib.new({
      redstone_router = get_rs_router(), config_path = "/xreactor/config/reproc_routes.lua",
      routing_load_status = routing_load_status,
      log = function(level, msg) utils.log("REPROC", msg, level) end,
      get_reactors = function()
        local list, seen = {}, {}
        local fd = config.feed or {}
        for _, entry in ipairs(fd.targets or {}) do
          local label = entry.label or entry.inlet or "?"
          local id = entry.label or label
          if not seen[id] then seen[id] = true; list[#list + 1] = { id = id, label = label } end
        end
        if #list == 0 then
          for _, name in ipairs(peripheral.getNames() or {}) do
            local ptype = tostring(peripheral.getType(name) or ""):lower()
            if ptype:find("reprocessor") or name:lower():find("reprocessor") then
              if not seen[name] then seen[name] = true; list[#list + 1] = { id = name, label = name } end
            end
          end
        end
        return list
      end,
    })
  end
  return router_ui_instance
end

local function handle_command(message)
  local cmd, parse_error = support_command_handler.parse_node_command(message, { protocol = protocol, comms = comms })
  if parse_error then return support_command_handler.finish_with_result(devices, parse_error) end
  if not cmd then return end
  if cmd.target == constants.command_targets.MODE and cmd.value == constants.node_states.OFF then enter_standby("MODE_OFF")
  elseif cmd.target == constants.command_targets.MODE and cmd.value == constants.node_states.RUNNING then standby = false
  else return support_command_handler.reject_unsupported(devices) end
  return support_command_handler.finish(devices, true)
end

local function init()
  services = service_manager.new({ log_prefix = "REPROC" })
  comms = comms_service.new({
    config = config, log_prefix = "REPROC", on_command = handle_command,
    on_message = function(message)
      if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then devices.proto_mismatch = true; return end
      if message.role == constants.roles.MASTER then
        master_seen = os.epoch("utc")
        if message.type == constants.message_types.STATUS and message.payload and message.payload.alerts then master_alerts = message.payload.alerts end
        -- Nur innerhalb der message.role==MASTER-Pruefung -- ein HELLO von
        -- irgendeiner anderen Node darf den Standby nicht aufheben.
        if message.type == constants.message_types.HELLO then standby = false end
      end
    end
  })
  services:add(comms)
  -- Gleiche Verdrahtung wie bei FUEL: der dedizierte Ventilkanal (6504)
  -- laeuft ausserhalb von comms_service.
  services:add({ name = "valve_ack_listener", wants_events = true, tick = function(_self, dt, event)
    if not event or event[1] ~= "modem_message" then return end
    local channel, message = event[3], event[5]
    if channel ~= constants.channels.VALVE then return end
    if type(message) == "table" and message.type == "VALVE_ACK" then
      get_rs_router():handle_valve_ack(message)
    end
  end })
  local last_valve_retry_check_ms = 0
  services:add({ name = "valve_ack_retry", tick = function()
    local now = os.epoch and os.epoch("utc") or 0
    if now - last_valve_retry_check_ms < 1000 then return end
    last_valve_retry_check_ms = now
    get_rs_router():check_pending_acks()
  end })
  -- "Weg 3"-Route-Teach-in -- identisch zu nodes/fuel/main.lua's
  -- Verdrahtung, da router_ui.lua/redstone_router.lua geteilt werden.
  services:add({ name = "valve_teach_listener", wants_events = true, tick = function(_self, dt, event)
    if not event or event[1] ~= "modem_message" then return end
    local channel, message = event[3], event[5]
    if channel ~= constants.channels.VALVE then return end
    if type(message) == "table" and message.type == "ROUTE_TEACH_PULSE" and router_ui_instance then
      router_ui_instance:handle_teach_pulse(message.src)
    end
  end })
  local discovery_stability_cache = discovery_stability.new({})
  services:add(discovery_service.new({
    registry = registry, discover = discover, interval = config.discovery_interval or config.heartbeat_interval,
    should_discover = function(service, ts, event, due)
      return discovery_stability_cache:should_discover(ts, event, due, service and service.interval)
    end,
    managed_registry = false, update_health = function(ok) devices.discovery_failed = not ok end
  }))
  services:add(telemetry_service.new({ comms = comms, status_interval = config.status_interval or config.heartbeat_interval, heartbeat_interval = config.heartbeat_interval, build_payload = build_status_payload, heartbeat_state = function() return { standby = standby } end }))
  services:add(ui_service.new({
    interval = 1,
    snapshot = function()
      local payload = build_status_payload(); local peer = master_peer_state(); local nid = comms and comms.network and comms.network.id or config.node_id
      local alert_payload = master_alerts and master_alerts.by_node and master_alerts.by_node[nid] or nil
      return { page = monitor_router and monitor_router.index or 1, payload = payload, master_state = peer and (peer.down and "DOWN" or "OK") or "UNKNOWN", standby = standby, alerts = alert_payload and alert_payload.critical or 0, last_command = devices.last_command, last_command_ts = devices.last_command_ts }
    end,
    render = render_monitor,
    handle_input = function(event) handle_monitor_touch(event) end
  }))
  services:init()
  hello()
  local ok_report_mod, report_mod = pcall(require, "core.startup_report")
  if ok_report_mod then
    pcall(function()
      local checks = { report_mod.check_wireless_modem() }
      local ok_spk, spk_mod = pcall(require, "optional.speaker_alarm")
      local speaker = ok_spk and spk_mod.new() or nil
      report_mod.run(checks, { log = function(_, msg) utils.log("REPROC", msg, "INFO") end, speaker = speaker })
    end)
  end
  utils.log("REPROC", "Node ready: " .. comms.network.id)
end

init()
-- Expliziter Quiesce-Handler, nutzt die bereits vorhandene, idempotente
-- enter_standby()-Funktion -- kein neuer Aktor-Code.
local quiesce_handshake = _G.__xreactor_update_handshake
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function()
  -- Stale-Pruefung VOR process_buffers()/feed-Arbeit, damit ein gerade
  -- abgelaufenes MASTER-Timeout sofort wirkt statt erst ab dem naechsten Zyklus.
  if os.epoch("utc") - master_seen > config.heartbeat_interval * 6000 then enter_standby("MASTER_STALE") end
  process_buffers()
  if not standby then get_feed_router():tick() end
  -- Treibt die asynchrone Ventil-Transaktion voran -- laeuft unbedingt jeden
  -- Zyklus; im Standby ist es dank enter_standby()'s sofortigem shutdown_now()
  -- nur noch ein billiger No-Op (keine Transaktion mehr vorhanden).
  get_rs_router():tick()
end, quiesce_handshake and { handshake = quiesce_handshake, on_quiesce = function()
  enter_standby("UPDATE_QUIESCE")
  local rs_router = get_rs_router()
  rs_router:begin_quiesce("UPDATE_QUIESCE")
  return standby == true and rs_router:poll_quiesce()
end } or nil)
