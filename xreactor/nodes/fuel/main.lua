local CONFIG = {
  LOG_NAME = "fuel",
  LOG_PREFIX = "FUEL",
  DEBUG_LOG_ENABLED = nil,
  BOOTSTRAP_LOG_ENABLED = false,
  BOOTSTRAP_LOG_PATH = nil,
  NODE_ID_PATH = "/xreactor/config/node_id.txt",
  CONFIG_PATH = nil,
  RECEIVE_TIMEOUT = 0.5
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({ role = "fuel", log_enabled = false, log_path = nil })
local require = bootstrap.require
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local health = require("core.health")
local ui = require("core.ui")
local core_ui_router = require("core.ui_router")
local colors = require("shared.colors")
local registry_lib = require("core.registry")
local monitor_adapter = require("adapters.monitor")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local telemetry_service = require("services.telemetry_service")
local discovery_service = require("services.discovery_service")
local ui_service = require("services.ui_service")
local safety = require("core.safety")
local non_rt_payload = require("core.non_rt_payload")
local support_discovery = require("nodes.support.discovery")
local support_runtime = require("nodes.support.runtime")
local role_logic = require("nodes.support.role_logic")
local support_ui_pages = require("nodes.support.ui_pages")
local support_command_handler = require("nodes.support.command_handler")
local role_descriptor = require("nodes.fuel.role_descriptor")
local config_normalizer = require("nodes.fuel.config_normalizer")
local logistics_router = require("nodes.fuel.logistics_router")
local redstone_router_lib = require("nodes.fuel.redstone_router")
local router_ui_lib = require("nodes.fuel.router_ui")
local fuel_ui_pages = require("nodes.fuel.ui_pages")

-- Feature (2026-07-09): Modularisierungs-Rewrite. main.lua ist jetzt nur
-- noch Orchestrierung (Wiring von Config/Services/Event-Loop) -- die
-- eigentliche Logik lebt in eigenstaendigen Modulen, analog zu nodes/rt/:
--   status_snapshot.lua      Status-Payload-Aufbau
--   command_handler.lua      Kommando-Parsing/Dispatch
--   fuel_status_network.lua  Netzwerkbasierter Reaktor-Fuellstand-Cache
--   monitor_ui.lua           Hauptmonitor + Ampel
--   storage.lua              Fluessig-Reserve-Tracking (storage_bus)
local status_snapshot_lib = require("nodes.fuel.status_snapshot")
local fuel_command_handler = require("nodes.fuel.command_handler")
local fuel_status_network = require("nodes.fuel.fuel_status_network")
local fuel_monitor_ui = require("nodes.fuel.monitor_ui")
local fuel_storage = require("nodes.fuel.storage")

local DEFAULT_CONFIG = {
  role = constants.roles.FUEL_NODE,
  node_id = "FUEL-1",
  debug_logging = false,
  reset_log_on_start = true,
  wireless_modem = nil,
  wired_modem = nil,
  storage_bus = "meBridge_0",
  target = 2000,
  minimum_reserve = 2000,
  heartbeat_interval = 2,
  discovery_interval = 15,
  status_interval = 5,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
  comms = {
    ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0
  }
}

CONFIG.CONFIG_PATH = role_descriptor.config_path
local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}
local function add_config_warning(message) table.insert(config_warnings, message) end
config_normalizer.normalize(config, DEFAULT_CONFIG, add_config_warning, utils)

local node_id = support_runtime.init_logging({
  utils = utils, config = config, runtime_config = CONFIG,
  config_meta = config_meta, config_warnings = config_warnings
})

local comms
local services
local registry = registry_lib.new({ node_id = node_id, role = role_descriptor.role_key, log_prefix = CONFIG.LOG_PREFIX })
local fuel_health = health.new({})
local router
local rs_router_instance
local router_ui_instance
local fuel_status_cache = fuel_status_network.new()
local devices = {
  monitor = nil, monitor_name = nil, storage_name = nil, discovery_failed = false,
  registry_summary = nil, registry_load_error = nil, proto_mismatch = false,
  last_scan_ts = nil, last_command = nil, last_command_ts = nil
}
local master_alerts = {}
local reserve = config.minimum_reserve
local master_seen_ts = nil
local fuel_ui = fuel_ui_pages.new({ ui = ui, colors = colors, support_ui_pages = support_ui_pages, utils = utils, config = config, devices = devices })

local function warn_once(key, message)
  support_runtime.warn_once(devices, function(msg, level) utils.log(CONFIG.LOG_PREFIX, msg, level) end, key, message)
end

local function get_rs_router()
  if not rs_router_instance then
    rs_router_instance = redstone_router_lib.new({
      config = config,
      log = function(level, msg) utils.log("FUEL", msg, level) end,
      warn_once = function(key, msg) warn_once(key, msg) end,
      comms = comms,
    })
  end
  return rs_router_instance
end

local function get_router()
  if not router then
    router = logistics_router.new({
      config = config,
      log = function(level, msg) utils.log("FUEL", msg, level) end,
      warn_once = function(key, msg) warn_once(key, msg) end,
      rs_router = get_rs_router(),
      fuel_status = fuel_status_cache,
    })
  end
  return router
end

local function get_router_ui()
  if not router_ui_instance then
    router_ui_instance = router_ui_lib.new({
      redstone_router = get_rs_router(),
      config_path = "/xreactor/config/fuel_routes.lua",
      log = function(level, msg) utils.log("FUEL", msg, level) end,
      get_reactors = function()
        local list, seen = {}, {}
        local lg = config.logistics or {}
        for _, entry in ipairs(lg.reactors or {}) do
          local label = entry.name or entry.label or entry.reactor_id or entry.reactor_port or "?"
          local id = entry.label or entry.name or label
          if not seen[id] then seen[id] = true; list[#list + 1] = { id = id, label = label } end
        end
        if #list == 0 then
          for _, name in ipairs(peripheral.getNames() or {}) do
            local ptype = tostring(peripheral.getType(name) or ""):lower()
            if ptype:find("reactor") or name:lower():find("reactor") then
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

local function discover()
  local names
  local registry_devices
  local monitor_entry = monitor_adapter.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  local monitor_name = monitor_entry and monitor_entry.name or nil
  devices.monitor = monitor_entry and monitor_entry.mon or nil
  devices.monitor_name = monitor_name
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current(); devices.monitor_name = devices.monitor_name or "term"; devices.monitor_is_term = true
  end
  registry_devices, names = support_discovery.collect_monitor_device(utils, monitor_name)
  local storage_devices = support_discovery.collect_devices_by_methods(names, {
    kind = "storage",
    allow_name = function(name) return not config.storage_bus or name == config.storage_bus end,
    match = function(method_set) return method_set.tanks or method_set.getFluidAmount end
  })
  for _, entry in ipairs(storage_devices) do table.insert(registry_devices, entry) end
  registry:sync(registry_devices)
  devices.registry_summary = registry:get_summary()
  devices.registry_load_error = registry.state.load_error
  devices.last_scan_ts = os.epoch("utc")
  local bound = registry:get_bound_devices("storage")
  devices.storage_name = bound[1] and bound[1].name or nil
  fuel_storage.refresh(devices, utils)
end

local function hello() comms:send_hello({ reserve = reserve }) end

local is_master_connected
local master_peer_state

local function build_status_payload()
  return status_snapshot_lib.build_status_payload({
    config = config, devices = devices, fuel_health = fuel_health,
    comms = comms, registry = registry, health = health,
    non_rt_payload = non_rt_payload, master_alerts = master_alerts,
    master_seen_ts = master_seen_ts, reserve = reserve, storage = fuel_storage.get(),
    read_fuel = function() return fuel_storage.read_fuel(warn_once, support_runtime) end,
    enforce_reserve = function(current) return fuel_storage.enforce_reserve(current, reserve, safety, utils) end,
    is_master_connected = is_master_connected, get_router = get_router,
  })
end

local function render_monitor()
  fuel_monitor_ui.render_monitor({
    devices = devices, build_status_payload = build_status_payload, comms = comms,
    master_peer_state = master_peer_state, registry = registry, config = config,
    master_alerts = master_alerts, support_ui_pages = support_ui_pages,
    ui_router = core_ui_router, fuel_ui = fuel_ui, get_router_ui = get_router_ui,
    ui = ui, colors = colors, keys = keys,
  })
end

local function render_ampel()
  fuel_monitor_ui.render_ampel({
    build_status_payload = build_status_payload, master_peer_state = master_peer_state, devices = devices,
  })
end

local function handle_monitor_touch(x, y)
  return fuel_monitor_ui.handle_touch(x, y)
end

local function handle_command(message)
  return fuel_command_handler.handle(message, {
    support_command_handler = support_command_handler, constants = constants,
    devices = devices, protocol = protocol, comms = comms, utils = utils,
    set_reserve = function(v) reserve = v end,
    on_fuel_status = function(value) fuel_status_network.ingest_master_relay(fuel_status_cache, value) end,
  })
end

master_peer_state = function() return role_logic.master_peer_state(comms, constants.roles.MASTER) end
is_master_connected = function()
  return role_logic.is_master_connected({ comms = comms, master_role = constants.roles.MASTER, last_seen_ts = master_seen_ts, heartbeat_interval = config.heartbeat_interval })
end

local function init()
  -- Fix (2026-07-09): sofortige, direkte Monitor-Ersterkennung hier
  -- (synchron, vor dem Event-Loop) -- discover() aktualisiert/bestaetigt
  -- das danach weiter periodisch.
  local mon_entry = monitor_adapter.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  devices.monitor = mon_entry and mon_entry.mon or nil
  devices.monitor_name = mon_entry and mon_entry.name or nil
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current(); devices.monitor_name = devices.monitor_name or "term"; devices.monitor_is_term = true
  end
  utils.log(CONFIG.LOG_PREFIX, "Monitor-Erstinit: " .. tostring(devices.monitor_name)
    .. (devices.monitor and "" or " (KEIN Monitor gefunden!)"), devices.monitor and "INFO" or "WARN")

  services = service_manager.new({ log_prefix = "FUEL" })
  comms = comms_service.new({
    config = config, log_prefix = "FUEL", on_command = handle_command,
    on_message = function(message)
      if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then devices.proto_mismatch = true; return end
      if message.role == constants.roles.MASTER then
        master_seen_ts = os.epoch("utc")
        if message.type == constants.message_types.STATUS and message.payload and message.payload.alerts then master_alerts = message.payload.alerts end
      end
    end
  })
  services:add(comms)
  services:add(discovery_service.new({ registry = registry, discover = discover, interval = config.discovery_interval or config.heartbeat_interval, managed_registry = false, update_health = function(ok) devices.discovery_failed = not ok end }))
  services:add(telemetry_service.new({ comms = comms, status_interval = config.status_interval or config.heartbeat_interval, heartbeat_interval = config.heartbeat_interval, build_payload = build_status_payload, heartbeat_state = function() return { reserve = reserve } end }))
  services:add(ui_service.new({
    interval = 1,
    snapshot = function()
      local payload = build_status_payload(); local peer = master_peer_state(); local nid = comms and comms.network and comms.network.id or config.node_id
      local alert_payload = master_alerts and master_alerts.by_node and master_alerts.by_node[nid] or nil
      return { page = fuel_monitor_ui.current_page_index(), payload = payload, master_state = peer and (peer.down and "DOWN" or "OK") or "UNKNOWN", alerts = alert_payload and alert_payload.critical or 0, last_command = devices.last_command, last_command_ts = devices.last_command_ts }
    end,
    render = render_monitor,
    handle_input = function(event) fuel_monitor_ui.handle_touch(event and event[3], event and event[4]) end
  }))
  -- Fix (2026-07-09): eigener, von der Haupt-UI unabhaengiger Tick fuer
  -- die Ampel -- laeuft auch wenn (noch) kein Hauptmonitor gefunden
  -- wurde.
  local ampel_tick_acc = 0
  services:add({ name = "ampel_render", tick = function(_self, dt)
    ampel_tick_acc = ampel_tick_acc + (tonumber(dt) or 0.5)
    if ampel_tick_acc < 1 then return end
    ampel_tick_acc = 0
    render_ampel()
  end })
  services:add({ name = "router_touch", tick = function(_self, dt, event) if event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then handle_monitor_touch(event[3], event[4]) end end })
  services:add(fuel_status_network.make_overhear_service(fuel_status_cache, constants))
  services:init()
  hello()
  local ok_report_mod, report_mod = pcall(require, "core.startup_report")
  if ok_report_mod then
    pcall(function()
      local checks = { report_mod.check_wireless_modem() }
      checks[#checks + 1] = { name = "Storage-Bus gefunden", ok = fuel_storage.get() ~= nil }
      local ok_spk, spk_mod = pcall(require, "optional.speaker_alarm")
      local speaker = ok_spk and spk_mod.new() or nil
      report_mod.run(checks, { log = function(_, msg) utils.log("FUEL", msg, "INFO") end, speaker = speaker })
    end)
  end
  utils.log("FUEL", "Node ready: " .. comms.network.id)
end

init()
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() get_router():tick() end)
