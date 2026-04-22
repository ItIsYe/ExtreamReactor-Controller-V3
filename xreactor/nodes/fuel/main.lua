-- CONFIG
local CONFIG = {
  LOG_NAME = "fuel", -- Log file name for this node.
  LOG_PREFIX = "FUEL", -- Default log prefix for fuel events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_fuel.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = nil, -- Config file path (provided by role descriptor).
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
local non_rt_payload = require("core.non_rt_payload")
local support_discovery = require("nodes.support.discovery")
local support_runtime = require("nodes.support.runtime")
local role_descriptor = require("nodes.fuel.role_descriptor")
local config_normalizer = require("nodes.fuel.config_normalizer")

local DEFAULT_CONFIG = {
  role = constants.roles.FUEL_NODE, -- Node role identifier.
  node_id = "FUEL-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor_logs/fuel.log.
  reset_log_on_start = true, -- Truncate runtime log at startup to keep disk usage bounded.
  wireless_modem = nil, -- Autodetect wireless modem unless explicitly configured.
  wired_modem = nil, -- Optional wired modem side.
  storage_bus = "meBridge_0", -- Default storage bus peripheral name.
  target = 2000, -- Default fuel reserve target.
  minimum_reserve = 2000, -- Minimum reserve used for safety.
  heartbeat_interval = 2, -- Seconds between status heartbeats.
  discovery_interval = 15, -- Seconds between peripheral rescans.
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

CONFIG.CONFIG_PATH = role_descriptor.config_path
local config, config_meta = utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
local config_warnings = {}

local function add_config_warning(message)
  table.insert(config_warnings, message)
end

config_normalizer.normalize(config, DEFAULT_CONFIG, add_config_warning, utils)

-- Initialize file logging early to capture startup events.
local node_id = support_runtime.init_logging({
  utils = utils,
  config = config,
  runtime_config = CONFIG,
  config_meta = config_meta,
  config_warnings = config_warnings
})

local comms
local services
local registry = registry_lib.new({ node_id = node_id, role = role_descriptor.role_key, log_prefix = CONFIG.LOG_PREFIX })
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
local warned = {}

local function warn_once(key, message)
  if warned[key] then return end
  warned[key] = true
  utils.log(CONFIG.LOG_PREFIX, message, "WARN")
end

local function safe_wrapped_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(obj[method], ...)
end

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
  local names
  local registry_devices
  local monitor_entry = monitor_adapter.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  local monitor_name = monitor_entry and monitor_entry.name or nil
  devices.monitor = monitor_entry and monitor_entry.mon or nil
  devices.monitor_name = monitor_name
  registry_devices, names = support_discovery.collect_monitor_device(utils, monitor_name)
  for _, name in ipairs(names) do
    if config.storage_bus and name ~= config.storage_bus then
      goto continue
    end
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then
      goto continue
    end
    local method_set = {}
    for _, method in ipairs(methods) do
      method_set[method] = true
    end
    if method_set.tanks or method_set.getFluidAmount then
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
  if storage and storage.tanks then
    local ok, tank_data = safe_wrapped_call(storage, "tanks")
    if ok and type(tank_data) == "table" then
      local total = 0
      for _, tank in pairs(tank_data) do
        if type(tank) == "table" and type(tank.amount) == "number" then
          total = total + tank.amount
        end
      end
      return total
    elseif not ok then
      warn_once("storage_read", "Storage tanks read failed: " .. tostring(tank_data))
    end
  end
  if storage and storage.getFluidAmount then
    local ok, value = safe_wrapped_call(storage, "getFluidAmount")
    if ok and type(value) == "number" then
      return value
    end
    if not ok then
      warn_once("storage_read_legacy", "Storage read failed: " .. tostring(value))
    end
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
  local payload = non_rt_payload.build_base({
    ts = os.epoch("utc"),
    role = config.role,
    node_id = config.node_id,
    health = {
      status = fuel_health.status,
      reasons = health.reasons_list(fuel_health),
      last_seen_ts = fuel_health.last_seen_ts,
      bindings = fuel_health.bindings,
      capabilities = fuel_health.capabilities
    },
    discovery_failed = devices.discovery_failed,
    master_connected = master_ok,
    master_seen_s = master_seen_ts and math.max(0, math.floor((os.epoch("utc") - master_seen_ts) / 1000)) or nil,
    queue = comms and comms:queue_depth() or 0,
    peers = comms and comms.peer_state and comms.peer_state.peers or nil,
    alerts = master_alerts,
    protocol_mismatch = devices.proto_mismatch,
    last_command = devices.last_command,
    last_command_ts = devices.last_command_ts,
    registry = {
      summary = devices.registry_summary or registry:get_summary(),
      devices = registry:get_devices_by_kind(),
      diagnostics = registry:get_diagnostics()
    }
  })
  payload.reserve = amount
  payload.minimum_reserve = reserve
  payload.sources = { { id = devices.storage_name or "unknown", amount = amount } }
  payload.bindings = fuel_health.bindings
  payload.bindings_summary = health.summarize_bindings(fuel_health.bindings)
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
    local w = select(1, ui.getSize(target))
    if not w then
      return
    end
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
          local w, h = ui.getSize(target)
          if not w or not h then
            return
          end
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
          local w, h = ui.getSize(target)
          if not w or not h then
            return
          end
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
          local w, h = ui.getSize(target)
          if not w or not h then
            return
          end
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
    interval = config.discovery_interval or config.heartbeat_interval,
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
    snapshot = function()
      local payload = build_status_payload()
      local peer = master_peer_state()
      local node_id = comms and comms.network and comms.network.id or config.node_id
      local alert_payload = master_alerts and master_alerts.by_node and master_alerts.by_node[node_id] or nil
      return {
        page = monitor_router and monitor_router.index or 1,
        payload = payload,
        master_state = peer and (peer.down and "DOWN" or "OK") or "UNKNOWN",
        alerts = alert_payload and alert_payload.critical or 0,
        last_command = devices.last_command,
        last_command_ts = devices.last_command_ts
      }
    end,
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
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms)
