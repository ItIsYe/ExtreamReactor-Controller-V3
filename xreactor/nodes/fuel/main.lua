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
local ui_router = require("core.ui_router")
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
-- Fix (2026-07-09): FUEL-Node rief das Ampel-Modul bisher ueberhaupt nie
-- auf (RT/Energy tun das schon laenger) -- der 1x3-Ampel-Monitor blieb
-- dadurch immer schwarz/inaktiv, egal wie er verkabelt war.
local ok_ampel_mod, ampel_mod = pcall(require, "optional.ampel")
local ampel_instance = ok_ampel_mod and type(ampel_mod) == "table" and type(ampel_mod.new) == "function" and ampel_mod.new() or nil
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
local storage
local router
local rs_router_instance
-- Feature (2026-07-08): Reaktor-Fuellstand kommt NICHT mehr per Wired-Modem
-- direkt vom Reaktor (FUEL hat keinen Zugriff darauf, nur aufs ME-System) —
-- stattdessen: primaer per Master-Relay (siehe master/fuel_relay.lua,
-- FUEL_STATUS-Kommando), mit Fallback auf direktes Mithoeren der RT->Master
-- Status-Broadcasts falls Master laengere Zeit nicht mehr relayed hat
-- (z.B. Master-Ausfall). Beide Quellen tragen ihre eigene Frische (ts) und
-- werden in logistics_router:read_reactor_fuel_from_network() zusammen-
-- gefuehrt (juengste gewinnt, mit Max-Alter-Schwelle).
local fuel_status_cache = {
  master_relay = {},   -- [reactor_id] = { fuel_amount, fuel_capacity, ts }
  direct_heard = {},   -- [reactor_id] = { fuel_amount, fuel_capacity, ts }
}
local router_ui_instance
local devices = {
  monitor = nil, monitor_name = nil, storage_name = nil, discovery_failed = false,
  registry_summary = nil, registry_load_error = nil, proto_mismatch = false,
  last_scan_ts = nil, last_command = nil, last_command_ts = nil
}
local master_alerts = {}
local reserve = config.minimum_reserve
local master_seen_ts = nil
local monitor_router = nil
local fuel_ui = fuel_ui_pages.new({ ui = ui, colors = colors, support_ui_pages = support_ui_pages, utils = utils, config = config, devices = devices })

local function warn_once(key, message)
  support_runtime.warn_once(devices, function(msg, level) utils.log(CONFIG.LOG_PREFIX, msg, level) end, key, message)
end

local function cache()
  storage = nil
  if devices.storage_name and peripheral.isPresent(devices.storage_name) then
    local wrapped, err = utils.safe_wrap(devices.storage_name)
    if wrapped then storage = wrapped else utils.log("FUEL", "WARN: storage bus wrap failed: " .. tostring(err)) end
  end
end

local function get_rs_router()
  if not rs_router_instance then
    rs_router_instance = redstone_router_lib.new({
      config = config,
      log = function(level, msg) utils.log("FUEL", msg, level) end,
      warn_once = function(key, msg) warn_once(key, msg) end,
      -- Feature (2026-07-09): fuer Auto-Discovery netzwerkbasierter
      -- VALVE-Nodes (siehe redstone_router.lua refresh()).
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
  local monitor_entry = monitor_adapter.find(nil, "largest", 0.5, CONFIG.LOG_PREFIX)
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
  cache()
end

local function hello() comms:send_hello({ reserve = reserve }) end

local function read_fuel()
  if storage and storage.tanks then
    local ok, tank_data = support_runtime.safe_wrapped_call(storage, "tanks")
    if ok and type(tank_data) == "table" then
      local total = 0
      for _, tank in pairs(tank_data) do if type(tank) == "table" and type(tank.amount) == "number" then total = total + tank.amount end end
      return total
    elseif not ok then warn_once("storage_read", "Storage tanks read failed: " .. tostring(tank_data)) end
  end
  if storage and storage.getFluidAmount then
    local ok, value = support_runtime.safe_wrapped_call(storage, "getFluidAmount")
    if ok and type(value) == "number" then return value end
    if not ok then warn_once("storage_read_legacy", "Storage read failed: " .. tostring(value)) end
  end
  return 0
end

local function enforce_reserve(current)
  local adjusted, changed = safety.with_reserve(current, reserve)
  if changed then utils.log("FUEL", "Reserve enforced at " .. adjusted) end
  return adjusted
end

local is_master_connected
local master_peer_state

local function build_status_payload()
  local amount = enforce_reserve(read_fuel())
  local has_storage = storage ~= nil
  local reasons = {}
  if not has_storage then reasons[health.reasons.NO_STORAGE] = true end
  if devices.discovery_failed or devices.registry_load_error then reasons[health.reasons.DISCOVERY_FAILED] = true end
  if devices.proto_mismatch then reasons[health.reasons.PROTO_MISMATCH] = true end
  local master_ok = is_master_connected()
  if not master_ok then reasons[health.reasons.COMMS_DOWN] = true end
  fuel_health.status = next(reasons) and health.status.DEGRADED or health.status.OK
  fuel_health.reasons = reasons
  fuel_health.last_seen_ts = os.epoch("utc")
  fuel_health.bindings = { storage = has_storage and 1 or 0 }
  fuel_health.capabilities = { storage = config.storage_bus ~= nil }
  local payload = non_rt_payload.build_base({
    ts = os.epoch("utc"), role = config.role, node_id = config.node_id,
    health = { status = fuel_health.status, reasons = health.reasons_list(fuel_health), last_seen_ts = fuel_health.last_seen_ts, bindings = fuel_health.bindings, capabilities = fuel_health.capabilities },
    discovery_failed = devices.discovery_failed, master_connected = master_ok,
    master_seen_s = master_seen_ts and math.max(0, math.floor((os.epoch("utc") - master_seen_ts) / 1000)) or nil,
    queue = comms and comms:queue_depth() or 0,
    peers = comms and comms.peer_state and comms.peer_state.peers or nil,
    alerts = master_alerts, protocol_mismatch = devices.proto_mismatch,
    last_command = devices.last_command, last_command_ts = devices.last_command_ts,
    registry = { summary = devices.registry_summary or registry:get_summary(), devices = registry:get_devices_by_kind(), diagnostics = registry:get_diagnostics() }
  })
  payload.reserve = amount
  payload.minimum_reserve = reserve
  payload.sources = { { id = devices.storage_name or "unknown", amount = amount } }
  payload.logistics = get_router():get_summary()
  payload.bindings = fuel_health.bindings
  payload.bindings_summary = health.summarize_bindings(fuel_health.bindings)
  return payload
end

-- Fix (2026-07-09): Ampel-Status fuer FUEL ableiten, analog zu rt_status()
-- in nodes/rt/monitor_ui.lua. Master-Verbindung > aktive Fehler > kritisch
-- niedriger Reaktor-Fuellstand > gerade aktive Lieferung > normal.
local function fuel_ampel_status(model)
  if model.master_state and model.master_state ~= "OK" then return "WARNING" end
  local logistics = (model.payload and model.payload.logistics) or {}
  if logistics.enabled == false then return "muted" end
  if tonumber(logistics.total_errors or 0) > 0 then return "WARNING" end
  for _, r in ipairs(logistics.reactors or {}) do
    if type(r.fuel_pct) == "number" and r.fuel_pct < 10 then return "EMERGENCY" end
  end
  if logistics.current_request then return "LIMITED" end
  return "OK"
end

local function render_monitor()
  if not devices.monitor then return end
  local mon = devices.monitor
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
  if not monitor_router then
    monitor_router = ui_router.new({
      pages = {
        { name = "Overview", render = function(target) return fuel_ui.render_overview(target, model) end },
        { name = "Details", render = function(target) return fuel_ui.render_details(target, model) end },
        { name = "Diagnostics", render = function(target) return fuel_ui.render_diagnostics(target, model) end,
          handle_touch = function(x, y) return fuel_ui.handle_diagnostics_touch(mon, x, y) end },
        { name = "Router", render = function(target) get_router_ui():render(target, ui, colors) end,
          handle_touch = function(x, y) return get_router_ui():handle_touch(x, y) end }
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true }
    })
  end
  monitor_router:render(mon, model)

  pcall(function()
    if not ampel_instance then return end
    ampel_instance.render(devices.monitor_name, fuel_ampel_status(model))
  end)
end

local function handle_monitor_touch(x, y)
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then return page.handle_touch(x, y) end
end

local function handle_command(message)
  local command, parse_error = support_command_handler.parse_node_command(message, { protocol = protocol, comms = comms })
  if parse_error then return support_command_handler.finish_with_result(devices, parse_error) end
  if not command then return end
  if command.target == constants.command_targets.SET_RESERVE then
    local new_reserve = tonumber(command.value)
    if type(new_reserve) == "number" and new_reserve >= 0 then reserve = new_reserve; utils.log("FUEL", "Reserve updated to " .. tostring(reserve))
    else
      utils.log("FUEL", "SET_RESERVE rejected: invalid value=" .. tostring(command.value), "WARN")
      return support_command_handler.finish_with_result(devices, { ok = false, error = "invalid reserve value", reason_code = "INVALID_VALUE" })
    end
  elseif command.target == constants.command_targets.FUEL_STATUS then
    -- Feature (2026-07-08): Master-Relay des Reaktor-Fuellstands (siehe
    -- master/fuel_relay.lua). value = { [reactor_id] = { fuel_amount,
    -- fuel_capacity, label, source_node, ts } }.
    if type(command.value) == "table" then
      local now = os.epoch("utc")
      for reactor_id, entry in pairs(command.value) do
        if type(entry) == "table" then
          fuel_status_cache.master_relay[reactor_id] = {
            fuel_amount = entry.fuel_amount,
            fuel_capacity = entry.fuel_capacity,
            ts = now,  -- lokale Empfangszeit, nicht die von Master gemeldete —
                       -- so bleibt die Frischepruefung unabhaengig von evtl.
                       -- abweichenden Uhren zwischen den Computern.
          }
        end
      end
    end
  elseif command.target == constants.command_targets.MODE and command.value == constants.node_states.MANUAL then
  else
    return support_command_handler.reject_unsupported(devices)
  end
  return support_command_handler.finish(devices, true)
end

master_peer_state = function() return role_logic.master_peer_state(comms, constants.roles.MASTER) end
is_master_connected = function()
  return role_logic.is_master_connected({ comms = comms, master_role = constants.roles.MASTER, last_seen_ts = master_seen_ts, heartbeat_interval = config.heartbeat_interval })
end

local function init()
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
      return { page = monitor_router and monitor_router.index or 1, payload = payload, master_state = peer and (peer.down and "DOWN" or "OK") or "UNKNOWN", alerts = alert_payload and alert_payload.critical or 0, last_command = devices.last_command, last_command_ts = devices.last_command_ts }
    end,
    render = render_monitor,
    handle_input = function(event) if monitor_router then monitor_router:handle_input(event) end end
  }))
  services:init()
  hello()
  local ok_report_mod, report_mod = pcall(require, "core.startup_report")
  if ok_report_mod then
    pcall(function()
      local checks = { report_mod.check_wireless_modem() }
      checks[#checks + 1] = { name = "Storage-Bus gefunden", ok = storage ~= nil }
      local ok_spk, spk_mod = pcall(require, "optional.speaker_alarm")
      local speaker = ok_spk and spk_mod.new() or nil
      report_mod.run(checks, { log = function(_, msg) utils.log("FUEL", msg, "INFO") end, speaker = speaker })
    end)
  end
  utils.log("FUEL", "Node ready: " .. comms.network.id)
end

init()
services:add({ name = "router_touch", tick = function(dt, event) if event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then handle_monitor_touch(event[3], event[4]) end end })

-- Feature (2026-07-08): Fallback-Pfad fuer den Reaktor-Fuellstand, falls
-- Master laengere Zeit nicht relayed hat (z.B. Master-Ausfall). Der
-- STATUS-Kanal (6501) ist auf jedem Node ohnehin schon geoeffnet (siehe
-- core/network.lua open_modem()) — hier wird er zusaetzlich passiv
-- mitgehoert, ohne selbst etwas zu senden. RT-Status-Broadcasts, die
-- eigentlich an MASTER gerichtet sind, werden dabei ignoriert von allen
-- die nicht danach suchen; wir lesen hier nur mit, senden nichts.
services:add({ name = "fuel_status_overhear", tick = function(dt, event)
  if not (event and event[1] == "modem_message") then return end
  local message = event[5]
  if type(message) ~= "table" then return end
  if message.type ~= constants.message_types.STATUS then return end
  if message.role ~= constants.roles.RT_NODE then return end
  local reactors = message.payload and message.payload.reactors
  if type(reactors) ~= "table" then return end
  local now = os.epoch("utc")
  for _, r in ipairs(reactors) do
    if type(r) == "table" and r.id and (r.fuel_amount ~= nil or r.fuel_capacity ~= nil) then
      fuel_status_cache.direct_heard[r.id] = {
        fuel_amount = r.fuel_amount,
        fuel_capacity = r.fuel_capacity,
        ts = now,
      }
    end
  end
end })
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() get_router():tick() end)
