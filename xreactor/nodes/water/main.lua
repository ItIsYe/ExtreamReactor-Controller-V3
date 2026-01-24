-- CONFIG
local CONFIG = {
  LOG_NAME = "water", -- Log file name for this node.
  LOG_PREFIX = "WATER", -- Default log prefix for water events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_water.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = "/xreactor/nodes/water/config.lua", -- Config file path.
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "water",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
local require = bootstrap.require
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local health = require("core.health")
local ui = require("core.ui")
local colors = require("shared.colors")
local registry_lib = require("core.registry")
local monitor_adapter = require("adapters.monitor")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local telemetry_service = require("services.telemetry_service")
local discovery_service = require("services.discovery_service")
local ui_service = require("services.ui_service")
local safety = require("core.safety")

local DEFAULT_CONFIG = {
  role = constants.roles.WATER_NODE, -- Node role identifier.
  node_id = "WATER-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor/logs/water.log.
  wireless_modem = "right", -- Default wireless modem side.
  wired_modem = nil, -- Optional wired modem side.
  loop_tanks = { "dynamicTank_0" }, -- Default tank peripheral names.
  target_volume = 200000, -- Desired tank volume.
  heartbeat_interval = 2, -- Seconds between status heartbeats.
  status_interval = 5, -- Seconds between status payloads.
  channels = {
    control = constants.channels.CONTROL, -- Control channel for MASTER commands.
    status = constants.channels.STATUS -- Status channel for telemetry.
  },
  comms = {
    ack_timeout_s = 3.0, -- Seconds before retrying a command.
    max_retries = 4, -- Maximum retries per message.
    backoff_base_s = 0.6, -- Base backoff seconds.
    backoff_cap_s = 6.0, -- Max backoff seconds.
    dedupe_ttl_s = 30, -- Seconds to keep dedupe entries.
    dedupe_limit = 200, -- Max dedupe entries per peer.
    peer_timeout_s = 12.0, -- Seconds before marking peer down.
    queue_limit = 200, -- Max queued outbound messages.
    drop_simulation = 0 -- Drop rate (0-1) for testing comms.
  }
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
  if type(config_values.loop_tanks) ~= "table" then
    config_values.loop_tanks = utils.deep_copy(defaults.loop_tanks)
    add_config_warning("loop_tanks missing/invalid; defaulting to configured list")
  end
  if type(config_values.target_volume) ~= "number" or config_values.target_volume < 0 then
    config_values.target_volume = defaults.target_volume
    add_config_warning("target_volume missing/invalid; defaulting to " .. tostring(defaults.target_volume))
  end
  if type(config_values.heartbeat_interval) ~= "number" or config_values.heartbeat_interval <= 0 then
    config_values.heartbeat_interval = defaults.heartbeat_interval
    add_config_warning("heartbeat_interval missing/invalid; defaulting to " .. tostring(defaults.heartbeat_interval))
  elseif config_values.heartbeat_interval > 60 then
    config_values.heartbeat_interval = 60
    add_config_warning("heartbeat_interval too high; clamping to 60s")
  end
  if type(config_values.status_interval) ~= "number" or config_values.status_interval <= 0 then
    config_values.status_interval = defaults.status_interval
    add_config_warning("status_interval missing/invalid; defaulting to " .. tostring(defaults.status_interval))
  elseif config_values.status_interval > 60 then
    config_values.status_interval = 60
    add_config_warning("status_interval too high; clamping to 60s")
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
  if type(config_values.comms) ~= "table" then
    config_values.comms = utils.deep_copy(defaults.comms)
    add_config_warning("comms config missing/invalid; defaulting to comms defaults")
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
utils.log(CONFIG.LOG_PREFIX, "Startup", "INFO")
if config_meta and config_meta.reason then
  utils.log(CONFIG.LOG_PREFIX, "Config issue (" .. tostring(config_meta.reason) .. ") at " .. tostring(config_meta.path) .. "; using defaults where needed.", "WARN")
end
for _, warning in ipairs(config_warnings) do
  utils.log(CONFIG.LOG_PREFIX, warning, "WARN")
end

local comms
local services
local registry = registry_lib.new({ node_id = node_id, role = "water", log_prefix = CONFIG.LOG_PREFIX })
local water_health = health.new({})
local tanks = {}
local devices = {
  monitor = nil,
  monitor_name = nil,
  discovery_failed = false,
  registry_summary = nil,
  registry_load_error = nil,
  proto_mismatch = false,
  last_scan_ts = nil
}
local last_heartbeat = 0
local master_seen_ts = nil

local function cache(bound_names)
  tanks = utils.cache_peripherals(bound_names or {})
end

local function discover()
  local names = peripheral.getNames() or {}
  local registry_devices = {}
  local allow_set = {}
  for _, name in ipairs(config.loop_tanks or {}) do
    allow_set[name] = true
  end
  local allow_all = #config.loop_tanks == 0
  local monitor_entry = monitor_adapter.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  local monitor_name = monitor_entry and monitor_entry.name or nil
  devices.monitor = monitor_entry and monitor_entry.mon or nil
  devices.monitor_name = monitor_name

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
    if not allow_all and not allow_set[name] then
      goto continue
    end
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then
      goto continue
    end
    local has_fluid = false
    for _, method in ipairs(methods) do
      if method == "getFluidAmount" then
        has_fluid = true
        break
      end
    end
    if has_fluid then
      table.insert(registry_devices, {
        name = name,
        type = peripheral.getType(name),
        methods = methods,
        kind = "tank",
        bound = true
      })
    end
    ::continue::
  end
  registry:sync(registry_devices)
  devices.registry_summary = registry:get_summary()
  devices.registry_load_error = registry.state.load_error
  devices.last_scan_ts = os.epoch("utc")
  local bound = registry:get_bound_devices("tank")
  local bound_names = {}
  for _, entry in ipairs(bound) do
    table.insert(bound_names, entry.name)
  end
  cache(bound_names)
end

local function hello()
  local summary = registry:get_summary()
  comms:send_hello({ tanks = summary.kinds.tank and summary.kinds.tank.bound or 0 })
end

local function total_water()
  local total = 0
  local buffers = {}
  for name, tank in pairs(tanks) do
    local level = tank.getFluidAmount and tank.getFluidAmount() or 0
    total = total + level
    table.insert(buffers, { id = name, level = level })
  end
  return total, buffers
end

local function balance_loop()
  local total, _ = total_water()
  if total < config.target_volume then
    utils.log("WATER", "Refill requested: " .. (config.target_volume - total))
  elseif total > config.target_volume * 1.1 then
    utils.log("WATER", "Bleed excess: " .. (total - config.target_volume))
  end
end

local function build_status_payload()
  local total, buffers = total_water()
  local reasons = {}
  if not next(tanks) then
    reasons[health.reasons.NO_STORAGE] = true
  end
  if devices.discovery_failed or devices.registry_load_error then
    reasons[health.reasons.DISCOVERY_FAILED] = true
  end
  if devices.proto_mismatch then
    reasons[health.reasons.PROTO_MISMATCH] = true
  end
  local master_ok = is_master_connected()
  if not master_ok then
    reasons[health.reasons.COMMS_DOWN] = true
  end
  water_health.status = next(reasons) and health.status.DEGRADED or health.status.OK
  water_health.reasons = reasons
  water_health.last_seen_ts = os.epoch("utc")
  water_health.bindings = { tanks = #buffers }
  water_health.capabilities = { tanks = #config.loop_tanks }
  return {
    total_water = total,
    buffers = buffers,
    health = {
      status = water_health.status,
      reasons = health.reasons_list(water_health),
      last_seen_ts = water_health.last_seen_ts,
      bindings = water_health.bindings,
      capabilities = water_health.capabilities
    },
    bindings = water_health.bindings,
    bindings_summary = health.summarize_bindings(water_health.bindings),
    registry = {
      summary = devices.registry_summary or registry:get_summary(),
      devices = registry:get_devices_by_kind(),
      diagnostics = registry:get_diagnostics()
    }
  }
end

local function format_age(ts, now)
  if not ts then
    return "n/a"
  end
  return ("%ds"):format(math.max(0, math.floor((now - ts) / 1000)))
end

local function render_monitor()
  if not devices.monitor then
    return
  end
  local mon = devices.monitor
  local w, h = mon.getSize()
  local payload = build_status_payload()
  local status = payload.health and payload.health.status or "OK"
  ui.panel(mon, 1, 1, w, h, "WATER NODE", status)
  ui.text(mon, 2, 2, ("ID: %s"):format(comms and comms.network and comms.network.id or config.node_id), colors.get("text"), colors.get("background"))
  ui.badge(mon, w - 6, 2, status, status)
  ui.text(mon, 2, 4, ("Total: %.0f"):format(payload.total_water or 0), colors.get("text"), colors.get("background"))
  ui.text(mon, 2, 5, ("Target: %.0f"):format(config.target_volume or 0), colors.get("text"), colors.get("background"))

  local comms_diag = comms and comms:get_diagnostics() or {}
  local metrics = comms_diag.metrics or {}
  local peer = master_peer_state()
  local master_state = peer and (peer.down and "DOWN" or "OK") or "UNKNOWN"
  local master_age = peer and peer.age and string.format("%ds", math.floor(peer.age)) or "n/a"
  local summary = payload.registry and payload.registry.summary or registry:get_summary()
  local rows = {
    { text = ("Discovery: %s"):format(devices.discovery_failed and "FAILED" or "OK"), status = devices.discovery_failed and "WARNING" or "OK" },
    { text = ("Last scan: %s"):format(format_age(devices.last_scan_ts, os.epoch("utc"))) },
    { text = ("Registry total:%d bound:%d missing:%d"):format(summary.total or 0, summary.bound or 0, summary.missing or 0) },
    { text = ("Master link: %s age:%s"):format(master_state, master_age) },
    { text = ("Comms q:%d inflight:%d retries:%d"):format(
      comms_diag.queue_depth or 0,
      comms_diag.inflight_count or 0,
      metrics.retries or 0
    ) },
    { text = ("Comms dropped:%d dedupe:%d timeouts:%d"):format(
      metrics.dropped or 0,
      metrics.dedupe_hits or 0,
      metrics.timeouts or 0
    ) }
  }
  ui.list(mon, 2, 7, w - 2, rows, { max_rows = h - 8 })
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
  if master_seen_ts then
    local age = (os.epoch("utc") - master_seen_ts) / 1000
    return age <= config.heartbeat_interval * 6, age
  end
  return false, nil
end

local function handle_command(message)
  if not protocol.is_for_node(message, comms.network.id) then return end
  local ok_proto = protocol.is_proto_compatible(message.proto_ver)
  if not ok_proto then
    return { ok = false, error = "proto mismatch", reason_code = "PROTO_MISMATCH" }
  end
  local payload = type(message.payload) == "table" and message.payload or nil
  local command = payload and payload.command
  if type(command) ~= "table" then
    return { ok = false, error = "invalid command", reason_code = "INVALID_COMMAND" }
  end
  return { ok = false, error = "unsupported command", reason_code = "UNSUPPORTED_COMMAND" }
end

local function init()
  discover()
  services = service_manager.new({ log_prefix = "WATER" })
  comms = comms_service.new({
    config = config,
    log_prefix = "WATER",
    on_command = handle_command,
    on_message = function(message)
      if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then
        devices.proto_mismatch = true
        return
      end
      if message.role == constants.roles.MASTER then
        master_seen_ts = os.epoch("utc")
      end
    end
  })
  services:add(comms)
  services:add(discovery_service.new({
    registry = registry,
    discover = discover,
    interval = config.heartbeat_interval,
    managed_registry = false,
    update_health = function(ok)
      devices.discovery_failed = not ok
    end
  }))
  services:add(telemetry_service.new({
    comms = comms,
    status_interval = config.status_interval or config.heartbeat_interval,
    heartbeat_interval = config.heartbeat_interval,
    build_payload = build_status_payload,
    heartbeat_state = function() return { tanks = #config.loop_tanks } end
  }))
  services:add(ui_service.new({
    interval = 1,
    render = render_monitor,
    handle_input = function() end
  }))
  services:init()
  hello()
  utils.log("WATER", "Node ready: " .. comms.network.id)
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
  balance_loop()
  services:tick()
end
