local CONFIG = {
  LOG_NAME = "water",
  LOG_PREFIX = "WATER",
  DEBUG_LOG_ENABLED = nil,
  BOOTSTRAP_LOG_ENABLED = false,
  BOOTSTRAP_LOG_PATH = nil,
  NODE_ID_PATH = "/xreactor/config/node_id.txt",
  CONFIG_PATH = nil,
  RECEIVE_TIMEOUT = 0.5
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({ role = "water", log_enabled = false, log_path = nil })
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
local redstone_router_lib = require("nodes.fuel.redstone_router")
local ui_service = require("services.ui_service")
local safety = require("core.safety")
local non_rt_payload = require("core.non_rt_payload")
local support_discovery = require("nodes.support.discovery")
local support_runtime = require("nodes.support.runtime")
local role_logic = require("nodes.support.role_logic")
local support_ui_pages = require("nodes.support.ui_pages")
local support_command_handler = require("nodes.support.command_handler")
local role_descriptor = require("nodes.water.role_descriptor")
local config_normalizer = require("nodes.water.config_normalizer")
local water_ui_pages = require("nodes.water.ui_pages")

local DEFAULT_CONFIG = {
  role = constants.roles.WATER_NODE,
  node_id = "WATER-1",
  debug_logging = false,
  reset_log_on_start = true,
  wireless_modem = nil,
  wired_modem = nil,
  loop_tanks = { "dynamicTank_0" },
  target_volume = 200000,
  balance_log_interval_s = 60,
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
local balance_log_state = { last_action = "ok", last_log_ts = 0 }
local cluster_rs_router = nil
local cluster_states = {}

local function add_config_warning(message) table.insert(config_warnings, message) end
config_normalizer.normalize(config, DEFAULT_CONFIG, add_config_warning, utils)

local node_id = support_runtime.init_logging({
  utils = utils, config = config, runtime_config = CONFIG,
  config_meta = config_meta, config_warnings = config_warnings
})

local comms
local services
local registry = registry_lib.new({ node_id = node_id, role = role_descriptor.role_key, log_prefix = CONFIG.LOG_PREFIX })
local water_health = health.new({})
local tanks = {}
local devices = {
  monitor = nil, monitor_name = nil, discovery_failed = false, registry_summary = nil,
  registry_load_error = nil, proto_mismatch = false, last_scan_ts = nil,
  last_command = nil, last_command_ts = nil
}
local master_alerts = {}
local master_seen_ts = nil
local monitor_router = nil
local water_ui = water_ui_pages.new({ ui = ui, colors = colors, support_ui_pages = support_ui_pages, utils = utils, config = config, devices = devices })

local function warn_once(key, message)
  support_runtime.warn_once(devices, function(msg, level) utils.log(CONFIG.LOG_PREFIX, msg, level) end, key, message)
end

local function cache(bound_names) tanks = utils.cache_peripherals(bound_names or {}) end

local function discover()
  local names
  local registry_devices
  local allow_set = {}
  for _, name in ipairs(config.loop_tanks or {}) do allow_set[name] = true end
  local allow_all = #config.loop_tanks == 0
  local monitor_entry = monitor_adapter.find(nil, "largest", 0.5, CONFIG.LOG_PREFIX)
  local monitor_name = monitor_entry and monitor_entry.name or nil
  devices.monitor = monitor_entry and monitor_entry.mon or nil
  devices.monitor_name = monitor_name
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current(); devices.monitor_name = devices.monitor_name or "term"; devices.monitor_is_term = true
  end
  registry_devices, names = support_discovery.collect_monitor_device(utils, monitor_name)
  local tank_devices = support_discovery.collect_devices_by_methods(names, {
    kind = "tank",
    allow_name = function(name) return allow_all or allow_set[name] end,
    match = function(method_set) return method_set.tanks or method_set.getFluidAmount end
  })
  for _, entry in ipairs(tank_devices) do table.insert(registry_devices, entry) end
  registry:sync(registry_devices)
  devices.registry_summary = registry:get_summary()
  devices.registry_load_error = registry.state.load_error
  devices.last_scan_ts = os.epoch("utc")
  local bound = registry:get_bound_devices("tank")
  local bound_names = {}
  for _, entry in ipairs(bound) do table.insert(bound_names, entry.name) end
  cache(bound_names)
end

local function hello()
  local summary = registry:get_summary()
  comms:send_hello({ tanks = summary.kinds.tank and summary.kinds.tank.bound or 0 })
end

local function total_water()
  local total, buffers = 0, {}
  for name, tank in pairs(tanks) do
    local level = 0
    if tank.tanks then
      local ok, tank_data = support_runtime.safe_wrapped_call(tank, "tanks")
      if ok and type(tank_data) == "table" then
        for _, info in pairs(tank_data) do if type(info) == "table" and type(info.amount) == "number" then level = level + info.amount end end
      elseif not ok then warn_once("tank_read:" .. tostring(name), "Tank read failed for " .. tostring(name) .. ": " .. tostring(tank_data)) end
    elseif tank.getFluidAmount then
      local ok, value = support_runtime.safe_wrapped_call(tank, "getFluidAmount")
      if ok and type(value) == "number" then level = value
      elseif not ok then warn_once("tank_read:" .. tostring(name), "Tank read failed for " .. tostring(name) .. ": " .. tostring(value)) end
    end
    total = total + level
    table.insert(buffers, { id = name, level = level })
  end
  return total, buffers
end

local function should_log_balance(action, now)
  if action ~= balance_log_state.last_action then
    balance_log_state.last_action = action; balance_log_state.last_log_ts = now; return true
  end
  local interval_s = math.max(0, tonumber(config.balance_log_interval_s) or 0)
  if interval_s <= 0 then return false end
  if now - balance_log_state.last_log_ts >= interval_s * 1000 then balance_log_state.last_log_ts = now; return true end
  return false
end

local function read_tank_level(tank_name)
  local t = tanks[tank_name]
  if not t then return nil end
  if t.tanks then
    local ok, data = support_runtime.safe_wrapped_call(t, "tanks")
    if ok and type(data) == "table" then
      local total = 0
      for _, info in pairs(data) do if type(info) == "table" and type(info.amount) == "number" then total = total + info.amount end end
      return total
    end
  elseif t.getFluidAmount then
    local ok, value = support_runtime.safe_wrapped_call(t, "getFluidAmount")
    if ok and type(value) == "number" then return value end
  end
  return nil
end

local function set_rs_output(side, state, integrator)
  if integrator then
    local ok, dev = pcall(peripheral.wrap, integrator)
    if ok and dev and type(dev.setOutput) == "function" then pcall(dev.setOutput, side, state) end
  else
    pcall(redstone.setOutput, side, state)
  end
end

local function manage_clusters()
  local clusters = config.clusters or {}
  if #clusters == 0 then return end
  for _, cluster in ipairs(clusters) do
    local name = cluster.name or "?"
    local tank_name = cluster.tank
    local min_vol = tonumber(cluster.min_volume) or 0
    local max_vol = tonumber(cluster.max_volume) or math.huge
    local fill_side, drain_side, integrator = cluster.fill_side, cluster.drain_side, cluster.integrator
    local level = tank_name and read_tank_level(tank_name)
    if level == nil then
      warn_once("cluster_read:" .. name, "Cluster " .. name .. ": tank not found: " .. tostring(tank_name))
      goto continue
    end
    cluster_states[name] = cluster_states[name] or { filling = false, draining = false }
    local state = cluster_states[name]
    if level < min_vol and not state.filling then
      state.filling = true; state.draining = false
      if fill_side then set_rs_output(fill_side, true, integrator) end
      if drain_side then set_rs_output(drain_side, false, integrator) end
      utils.log("WATER", ("Cluster %s: filling (level=%.0f < min=%.0f)"):format(name, level, min_vol))
    elseif level > max_vol and not state.draining then
      state.draining = true; state.filling = false
      if fill_side then set_rs_output(fill_side, false, integrator) end
      if drain_side then set_rs_output(drain_side, true, integrator) end
      utils.log("WATER", ("Cluster %s: draining (level=%.0f > max=%.0f)"):format(name, level, max_vol))
    elseif level >= min_vol and level <= max_vol and (state.filling or state.draining) then
      state.filling = false; state.draining = false
      if fill_side then set_rs_output(fill_side, false, integrator) end
      if drain_side then set_rs_output(drain_side, false, integrator) end
      utils.log("WATER", ("Cluster %s: in range (level=%.0f)"):format(name, level))
    end
    ::continue::
  end
end

local function balance_loop()
  local total = total_water()
  local now = os.epoch("utc")
  if total < config.target_volume then
    if should_log_balance("refill", now) then utils.log("WATER", "Refill requested: " .. (config.target_volume - total)) end
  elseif total > config.target_volume then
    if should_log_balance("bleed", now) then utils.log("WATER", "Bleed requested: " .. (total - config.target_volume)) end
  elseif should_log_balance("ok", now) then
    utils.log("WATER", "Water level within target range")
  end
end

local is_master_connected
local master_peer_state

local function build_status_payload()
  local total, buffers = total_water()
  local reasons = {}
  if not next(tanks) then reasons[health.reasons.NO_STORAGE] = true end
  if devices.discovery_failed or devices.registry_load_error then reasons[health.reasons.DISCOVERY_FAILED] = true end
  if devices.proto_mismatch then reasons[health.reasons.PROTO_MISMATCH] = true end
  local master_ok = is_master_connected()
  if not master_ok then reasons[health.reasons.COMMS_DOWN] = true end
  water_health.status = next(reasons) and health.status.DEGRADED or health.status.OK
  water_health.reasons = reasons
  water_health.last_seen_ts = os.epoch("utc")
  water_health.bindings = { tanks = #buffers }
  water_health.capabilities = { tanks = #config.loop_tanks }
  local payload = non_rt_payload.build_base({
    ts = os.epoch("utc"), role = config.role, node_id = config.node_id,
    health = { status = water_health.status, reasons = health.reasons_list(water_health), last_seen_ts = water_health.last_seen_ts, bindings = water_health.bindings, capabilities = water_health.capabilities },
    discovery_failed = devices.discovery_failed, master_connected = master_ok,
    master_seen_s = master_seen_ts and math.max(0, math.floor((os.epoch("utc") - master_seen_ts) / 1000)) or nil,
    queue = comms and comms:get_diagnostics().queue_depth or 0,
    peers = comms and comms.peer_state and comms.peer_state.peers or nil,
    alerts = master_alerts, protocol_mismatch = devices.proto_mismatch,
    last_command = devices.last_command, last_command_ts = devices.last_command_ts,
    registry = { summary = devices.registry_summary or registry:get_summary(), devices = registry:get_devices_by_kind(), diagnostics = registry:get_diagnostics() }
  })
  payload.total_water = total
  local cluster_info = {}
  for _, cluster in ipairs(config.clusters or {}) do
    local name = cluster.name or "?"
    local level = (cluster.tank and read_tank_level(cluster.tank)) or nil
    local st = cluster_states[name] or {}
    table.insert(cluster_info, { name = name, level = level, filling = st.filling or false, draining = st.draining or false, min = cluster.min_volume, max = cluster.max_volume })
  end
  payload.clusters = cluster_info
  payload.buffers = buffers
  payload.bindings = water_health.bindings
  payload.bindings_summary = health.summarize_bindings(water_health.bindings)
  return payload
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
        { name = "Overview", render = function(target) return water_ui.render_overview(target, model) end },
        { name = "Details", render = function(target) return water_ui.render_details(target, model) end },
        { name = "Diagnostics", render = function(target) return water_ui.render_diagnostics(target, model) end,
          handle_touch = function(x, y) return water_ui.handle_diagnostics_touch(mon, x, y) end }
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true }
    })
  end
  monitor_router:render(mon, model)
end

local function handle_monitor_touch(x, y)
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then return page.handle_touch(x, y) end
end

master_peer_state = function() return role_logic.master_peer_state(comms, constants.roles.MASTER) end
is_master_connected = function()
  return role_logic.is_master_connected({ comms = comms, master_role = constants.roles.MASTER, last_seen_ts = master_seen_ts, heartbeat_interval = config.heartbeat_interval })
end

local function handle_command(message)
  local command, parse_error = support_command_handler.parse_node_command(message, { protocol = protocol, comms = comms })
  if parse_error then return support_command_handler.finish_with_result(devices, parse_error) end
  if not command then return end
  if command.target == constants.command_targets.SET_TARGET then
    local new_target = tonumber(command.value)
    if type(new_target) == "number" and new_target >= 0 then
      config.target_volume = new_target
      utils.log("WATER", "Target volume updated to " .. tostring(new_target))
    else
      utils.log("WATER", "SET_TARGET rejected: invalid value=" .. tostring(command.value), "WARN")
      return support_command_handler.finish_with_result(devices, { ok = false, error = "invalid target value", reason_code = "INVALID_VALUE" })
    end
    return support_command_handler.finish(devices, true)
  end
  return support_command_handler.reject_unsupported(devices)
end

local function init()
  services = service_manager.new({ log_prefix = "WATER" })
  comms = comms_service.new({
    config = config, log_prefix = "WATER", on_command = handle_command,
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
  services:add(telemetry_service.new({ comms = comms, status_interval = config.status_interval or config.heartbeat_interval, heartbeat_interval = config.heartbeat_interval, build_payload = build_status_payload, heartbeat_state = function() return { tanks = #config.loop_tanks } end }))
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
      checks[#checks + 1] = { name = "Tanks gefunden", ok = tanks ~= nil and next(tanks) ~= nil }
      local ok_spk, spk_mod = pcall(require, "optional.speaker_alarm")
      local speaker = ok_spk and spk_mod.new() or nil
      report_mod.run(checks, { log = function(_, msg) utils.log("WATER", msg, "INFO") end, speaker = speaker })
    end)
  end
  utils.log("WATER", "Node ready: " .. comms.network.id)
end

init()
services:add({ name = "router_touch", tick = function(_self, dt, event) if event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then handle_monitor_touch(event[3], event[4]) end end })
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function() balance_loop(); manage_clusters() end)
