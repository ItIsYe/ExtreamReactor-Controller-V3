-- CONFIG
local CONFIG = {
  LOG_NAME = "fuel", -- Log file name for this node.
  LOG_PREFIX = "FUEL", -- Default log prefix for fuel events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_fuel.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = "/xreactor/nodes/fuel/config.lua", -- Config file path.
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "fuel",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
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

local DEFAULT_CONFIG = {
  role = constants.roles.FUEL_NODE, -- Node role identifier.
  node_id = "FUEL-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor/logs/fuel.log.
  wireless_modem = "right", -- Default wireless modem side.
  wired_modem = nil, -- Optional wired modem side.
  storage_bus = "meBridge_0", -- Default storage bus peripheral name.
  target = 2000, -- Default fuel reserve target.
  minimum_reserve = 2000, -- Minimum reserve used for safety.
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
  if config_values.storage_bus ~= nil and type(config_values.storage_bus) ~= "string" then
    config_values.storage_bus = defaults.storage_bus
    add_config_warning("storage_bus invalid; defaulting to " .. tostring(defaults.storage_bus))
  end
  if config_values.minimum_reserve == nil and type(config_values.target) == "number" then
    config_values.minimum_reserve = config_values.target
    add_config_warning("minimum_reserve missing; using target value " .. tostring(config_values.target))
  end
  if type(config_values.minimum_reserve) ~= "number" or config_values.minimum_reserve < 0 then
    config_values.minimum_reserve = defaults.minimum_reserve
    add_config_warning("minimum_reserve missing/invalid; defaulting to " .. tostring(defaults.minimum_reserve))
  end
  if type(config_values.target) ~= "number" or config_values.target < 0 then
    config_values.target = defaults.target
    add_config_warning("target missing/invalid; defaulting to " .. tostring(defaults.target))
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
local registry = registry_lib.new({ node_id = node_id, role = "fuel", log_prefix = CONFIG.LOG_PREFIX })
local fuel_health = health.new({})
local storage
local devices = {
  monitor = nil,
  monitor_name = nil,
  storage_name = nil,
  discovery_failed = false,
  registry_summary = nil,
  registry_load_error = nil,
  proto_mismatch = false,
  last_scan_ts = nil,
  last_command = nil,
  last_command_ts = nil
}
local master_alerts = {}
local last_heartbeat = 0
local reserve = config.minimum_reserve
local master_seen_ts = nil
local monitor_router = nil

local function cache()
  storage = nil
  if devices.storage_name and peripheral.isPresent(devices.storage_name) then
    local wrapped, err = utils.safe_wrap(devices.storage_name)
    if wrapped then
      storage = wrapped
    else
      utils.log("FUEL", "WARN: storage bus wrap failed: " .. tostring(err))
    end
  end
end

local function discover()
  local names = peripheral.getNames() or {}
  local registry_devices = {}
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
    if config.storage_bus and name ~= config.storage_bus then
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
        kind = "storage",
        bound = true
      })
    end
    ::continue::
  end
  registry:sync(registry_devices)
  devices.registry_summary = registry:get_summary()
  devices.registry_load_error = registry.state.load_error
  devices.last_scan_ts = os.epoch("utc")
  local bound = registry:get_bound_devices("storage")
  devices.storage_name = bound[1] and bound[1].name or nil
  cache()
end

local function hello()
  comms:send_hello({ reserve = reserve })
end

local function read_fuel()
  if storage and storage.getFluidAmount then
    return storage.getFluidAmount() or 0
  end
  return 0
end

local function enforce_reserve(current)
  local adjusted, changed = safety.with_reserve(current, reserve)
  if changed then
    utils.log("FUEL", "Reserve enforced at " .. adjusted)
  end
  return adjusted
end

local function build_status_payload()
  local amount = enforce_reserve(read_fuel())
  local has_storage = storage ~= nil
  local reasons = {}
  if not has_storage then
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
  fuel_health.status = next(reasons) and health.status.DEGRADED or health.status.OK
  fuel_health.reasons = reasons
  fuel_health.last_seen_ts = os.epoch("utc")
  fuel_health.bindings = { storage = has_storage and 1 or 0 }
  fuel_health.capabilities = { storage = config.storage_bus ~= nil }
  local payload = {
    reserve = amount,
    minimum_reserve = reserve,
    sources = { { id = devices.storage_name or "unknown", amount = amount } },
    health = {
      status = fuel_health.status,
      reasons = health.reasons_list(fuel_health),
      last_seen_ts = fuel_health.last_seen_ts,
      bindings = fuel_health.bindings,
      capabilities = fuel_health.capabilities
    },
    bindings = fuel_health.bindings,
    bindings_summary = health.summarize_bindings(fuel_health.bindings),
    registry = {
      summary = devices.registry_summary or registry:get_summary(),
      devices = registry:get_devices_by_kind(),
      diagnostics = registry:get_diagnostics()
    }
  }
  return payload
end

local function format_age(ts, now)
  if not ts then
    return "n/a"
  end
  return ("%ds"):format(math.max(0, math.floor((now - ts) / 1000)))
end

local function render_alert_banner(target, model)
  if model.local_alerts_critical and model.local_alerts_critical > 0 then
    local w, _ = target.getSize()
    local label = "CRIT " .. tostring(model.local_alerts_critical)
    ui.badge(target, w - (#label + 2), 1, label, "EMERGENCY")
  end
end

local function render_monitor()
  if not devices.monitor then
    return
  end
  local mon = devices.monitor
  local payload = build_status_payload()
  local comms_diag = comms and comms:get_diagnostics() or {}
  local metrics = comms_diag.metrics or {}
  local peer = master_peer_state()
  local summary = payload.registry and payload.registry.summary or registry:get_summary()
  local now = os.epoch("utc")
  local node_id = comms and comms.network and comms.network.id or config.node_id
  local alert_payload = master_alerts and master_alerts.by_node and master_alerts.by_node[node_id] or nil
  local local_alerts = alert_payload and alert_payload.top or {}
  local local_critical = alert_payload and alert_payload.critical or 0
  local model = {
    payload = payload,
    status = payload.health and payload.health.status or "OK",
    summary = summary,
    comms = comms_diag,
    metrics = metrics,
    master_state = peer and (peer.down and "DOWN" or "OK") or "UNKNOWN",
    master_age = peer and peer.age and string.format("%ds", math.floor(peer.age)) or "n/a",
    last_scan = format_age(devices.last_scan_ts, now),
    last_command = devices.last_command,
    last_command_ts = devices.last_command_ts and format_age(devices.last_command_ts, now) or "n/a",
    local_alerts = local_alerts,
    local_alerts_critical = local_critical,
    node_id = node_id
  }
  if not monitor_router then
    monitor_router = ui_router.new({
      pages = {
        { name = "Overview", render = function(target)
          local w, h = target.getSize()
          ui.panel(target, 1, 1, w, h, "FUEL NODE", model.status)
          render_alert_banner(target, model)
          ui.text(target, 2, 2, ("ID: %s"):format(model.node_id or "UNKNOWN"), colors.get("text"), colors.get("background"))
          ui.badge(target, w - 6, 2, model.status, model.status)
          ui.text(target, 2, 4, ("Reserve: %.0f"):format(model.payload.reserve or 0), colors.get("text"), colors.get("background"))
          ui.text(target, 2, 5, ("Minimum: %.0f"):format(model.payload.minimum_reserve or 0), colors.get("text"), colors.get("background"))
          ui.text(target, 2, 6, ("Storage: %s"):format(devices.storage_name or "none"), colors.get("text"), colors.get("background"))
          ui.text(target, 2, 8, ("Master link: %s age:%s"):format(model.master_state, model.master_age), colors.get("text"), colors.get("background"))
        end },
        { name = "Details", render = function(target)
          local w, h = target.getSize()
          ui.panel(target, 1, 1, w, h, "FUEL DETAILS", model.status)
          render_alert_banner(target, model)
          local rows = {
            { text = ("Registry total:%d bound:%d missing:%d"):format(model.summary.total or 0, model.summary.bound or 0, model.summary.missing or 0) },
            { text = ("Last scan: %s"):format(model.last_scan) },
            { text = ("Storage: %s"):format(devices.storage_name or "none") }
          }
          ui.list(target, 2, 3, w - 2, rows, { max_rows = h - 4 })
        end },
        { name = "Diagnostics", render = function(target)
          local w, h = target.getSize()
          ui.panel(target, 1, 1, w, h, "FUEL DIAGNOSTICS", model.status)
          render_alert_banner(target, model)
          local rows = {
            { text = ("Health: %s"):format(model.status), status = model.status },
            { text = ("Discovery: %s"):format(devices.discovery_failed and "FAILED" or "OK"), status = devices.discovery_failed and "WARNING" or "OK" },
            { text = ("Registry total:%d bound:%d missing:%d"):format(model.summary.total or 0, model.summary.bound or 0, model.summary.missing or 0) },
            { text = ("Master link: %s age:%s"):format(model.master_state, model.master_age) },
            { text = ("Comms q:%d inflight:%d retries:%d"):format(
              model.comms.queue_depth or 0,
              model.comms.inflight_count or 0,
              model.metrics.retries or 0
            ) },
            { text = ("Comms dropped:%d dedupe:%d timeouts:%d"):format(
              model.metrics.dropped or 0,
              model.metrics.dedupe_hits or 0,
              model.metrics.timeouts or 0
            ) },
            { text = ("Last cmd: %s (%s)"):format(model.last_command or "none", model.last_command_ts) }
          }
          if model.local_alerts and #model.local_alerts > 0 then
            table.insert(rows, { text = "Local Alerts:", status = "WARNING" })
            for _, alert in ipairs(model.local_alerts) do
              local sev = alert.severity and alert.severity:sub(1, 1) or "?"
              local title = alert.title or alert.message or alert.code or "alert"
              local status = alert.severity == "CRITICAL" and "EMERGENCY" or alert.severity == "WARN" and "WARNING" or "OK"
              table.insert(rows, { text = string.format("%s %s", sev, title), status = status })
            end
          end
          ui.list(target, 2, 3, w - 2, rows, { max_rows = h - 4 })
        end }
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true }
    })
  end
  monitor_router:render(mon, model)
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
    local result = { ok = false, error = "invalid command", reason_code = "INVALID_COMMAND" }
    devices.last_command = result.error
    devices.last_command_ts = os.epoch("utc")
    return result
  end
  if command.target == constants.command_targets.SET_RESERVE then
    reserve = command.value
  elseif command.target == constants.command_targets.MODE and command.value == constants.node_states.MANUAL then
    -- manual mode acknowledged but not changing behavior
  else
    local result = { ok = false, error = "unsupported command", reason_code = "UNSUPPORTED_COMMAND" }
    devices.last_command = result.error
    devices.last_command_ts = os.epoch("utc")
    return result
  end
  local result = { ok = true }
  devices.last_command = "ok"
  devices.last_command_ts = os.epoch("utc")
  return result
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

local function init()
  discover()
  services = service_manager.new({ log_prefix = "FUEL" })
  comms = comms_service.new({
    config = config,
    log_prefix = "FUEL",
    on_command = handle_command,
    on_message = function(message)
      if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then
        devices.proto_mismatch = true
        return
      end
      if message.role == constants.roles.MASTER then
        master_seen_ts = os.epoch("utc")
        if message.type == constants.message_types.STATUS and message.payload and message.payload.alerts then
          master_alerts = message.payload.alerts
        end
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
    heartbeat_state = function() return { reserve = reserve } end
  }))
  services:add(ui_service.new({
    interval = 1,
    render = render_monitor,
    handle_input = function(event)
      if monitor_router then
        monitor_router:handle_input(event)
      end
    end
  }))
  services:init()
  hello()
  utils.log("FUEL", "Node ready: " .. comms.network.id)
end

init()
while true do
  local timer = os.startTimer(CONFIG.RECEIVE_TIMEOUT)
  while true do
    local event = { os.pullEvent() }
    if event[1] == "modem_message" then
      comms:handle_event(event)
      services:tick(nil, event)
    elseif event[1] == "timer" and event[2] == timer then
      break
    elseif event[1] == "monitor_touch" or event[1] == "key" then
      services:tick(nil, event)
    end
  end
  services:tick()
end
