-- CONFIG
local CONFIG = {
  LOG_NAME = "water", -- Log file name for this node.
  LOG_PREFIX = "WATER", -- Default log prefix for water events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_water.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = nil, -- Config file path (provided by role descriptor).
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
local role_logic = require("nodes.support.role_logic")
local support_ui_pages = require("nodes.support.ui_pages")
local support_command_handler = require("nodes.support.command_handler")
local role_descriptor = require("nodes.water.role_descriptor")
local config_normalizer = require("nodes.water.config_normalizer")

local DEFAULT_CONFIG = {
  role = constants.roles.WATER_NODE, -- Node role identifier.
  node_id = "WATER-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor_logs/water.log.
  reset_log_on_start = true, -- Truncate runtime log at startup to keep disk usage bounded.
  wireless_modem = nil, -- Autodetect wireless modem unless explicitly configured.
  wired_modem = nil, -- Optional wired modem side.
  loop_tanks = { "dynamicTank_0" }, -- Default tank peripheral names.
  target_volume = 200000, -- Desired tank volume.
  balance_log_interval_s = 60, -- Seconds between repeated balance logs while refilling/bleeding (0 = only on state change).
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
local balance_log_state = { last_action = "ok", last_log_ts = 0 }

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
local water_health = health.new({})
local tanks = {}
local devices = {
  monitor = nil,
  monitor_name = nil,
  discovery_failed = false,
  registry_summary = nil,
  registry_load_error = nil,
  proto_mismatch = false,
  last_scan_ts = nil,
  last_command = nil,
  last_command_ts = nil
}
local master_alerts = {}
local master_seen_ts = nil
local monitor_router = nil

local function warn_once(key, message)
  support_runtime.warn_once(devices, function(msg, level)
    utils.log(CONFIG.LOG_PREFIX, msg, level)
  end, key, message)
end

local function cache(bound_names)
  tanks = utils.cache_peripherals(bound_names or {})
end

local function discover()
  local names
  local registry_devices
  local allow_set = {}
  for _, name in ipairs(config.loop_tanks or {}) do
    allow_set[name] = true
  end
  local allow_all = #config.loop_tanks == 0
  local monitor_entry = monitor_adapter.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  local monitor_name = monitor_entry and monitor_entry.name or nil
  devices.monitor = monitor_entry and monitor_entry.mon or nil
  devices.monitor_name = monitor_name
  -- Fallback: render to the computer's own terminal if no Monitor peripheral
  -- is attached, so Diagnostics (incl. log mode buttons) is visible on the PC.
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current()
    devices.monitor_name = devices.monitor_name or "term"
    devices.monitor_is_term = true
  end

  registry_devices, names = support_discovery.collect_monitor_device(utils, monitor_name)
  local tank_devices = support_discovery.collect_devices_by_methods(names, {
    kind = "tank",
    allow_name = function(name)
      return allow_all or allow_set[name]
    end,
    match = function(method_set)
      return method_set.tanks or method_set.getFluidAmount
    end
  })
  for _, entry in ipairs(tank_devices) do
    table.insert(registry_devices, entry)
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
    local level = 0
    if tank.tanks then
      local ok, tank_data = support_runtime.safe_wrapped_call(tank, "tanks")
      if ok and type(tank_data) == "table" then
        for _, info in pairs(tank_data) do
          if type(info) == "table" and type(info.amount) == "number" then
            level = level + info.amount
          end
        end
      elseif not ok then
        warn_once("tank_read:" .. tostring(name), "Tank read failed for " .. tostring(name) .. ": " .. tostring(tank_data))
      end
    elseif tank.getFluidAmount then
      local ok, value = support_runtime.safe_wrapped_call(tank, "getFluidAmount")
      if ok and type(value) == "number" then
        level = value
      elseif not ok then
        warn_once("tank_read:" .. tostring(name), "Tank read failed for " .. tostring(name) .. ": " .. tostring(value))
      end
    end
    total = total + level
    table.insert(buffers, { id = name, level = level })
  end
  return total, buffers
end

local function should_log_balance(action, now)
  if action ~= balance_log_state.last_action then
    balance_log_state.last_action = action
    balance_log_state.last_log_ts = now
    return true
  end
  local interval_s = math.max(0, tonumber(config.balance_log_interval_s) or 0)
  if interval_s <= 0 then
    return false
  end
  if now - balance_log_state.last_log_ts >= interval_s * 1000 then
    balance_log_state.last_log_ts = now
    return true
  end
  return false
end

local function balance_loop()
  local total, _ = total_water()
  local now = os.epoch("utc")
  if total < config.target_volume then
    if should_log_balance("refill", now) then
      utils.log("WATER", "Refill requested: " .. (config.target_volume - total))
    end
  elseif total > config.target_volume * 1.1 then
    if should_log_balance("bleed", now) then
      utils.log("WATER", "Bleed excess: " .. (total - config.target_volume))
    end
  elseif should_log_balance("ok", now) then
    utils.log("WATER", "Water level within target range")
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
  local payload = non_rt_payload.build_base({
    ts = os.epoch("utc"),
    role = config.role,
    node_id = config.node_id,
    health = {
      status = water_health.status,
      reasons = health.reasons_list(water_health),
      last_seen_ts = water_health.last_seen_ts,
      bindings = water_health.bindings,
      capabilities = water_health.capabilities
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
  payload.total_water = total
  payload.buffers = buffers
  payload.bindings = water_health.bindings
  payload.bindings_summary = health.summarize_bindings(water_health.bindings)
  return payload
end

local function render_monitor()
  if not devices.monitor then
    return
  end
  local mon = devices.monitor
  local payload = build_status_payload()
  local comms_diag = comms and comms:get_diagnostics() or {}
  local peer = master_peer_state()
  local summary = payload.registry and payload.registry.summary or registry:get_summary()
  local now = os.epoch("utc")
  local node_id = comms and comms.network and comms.network.id or config.node_id
  local alert_payload = master_alerts and master_alerts.by_node and master_alerts.by_node[node_id] or nil
  local local_alerts = alert_payload and alert_payload.top or {}
  local local_critical = alert_payload and alert_payload.critical or 0
  local model = support_ui_pages.build_common_model({
    payload = payload,
    summary = summary,
    comms_diag = comms_diag,
    master_peer = peer,
    now = now,
    last_scan_ts = devices.last_scan_ts,
    last_command = devices.last_command,
    last_command_ts = devices.last_command_ts,
    local_alerts = local_alerts,
    local_alerts_critical = local_critical,
    node_id = node_id
  })
  if not monitor_router then
    monitor_router = ui_router.new({
      pages = {
        { name = "Overview", render = function(target)
          local w, h = ui.getSize(target)
          if not w or not h then
            return
          end
          ui.panel(target, 1, 1, w, h, "WATER NODE", model.status)
          support_ui_pages.render_alert_banner(target, ui, model)
          ui.text(target, 2, 2, ("ID: %s"):format(model.node_id or "UNKNOWN"), colors.get("text"), colors.get("background"))
          ui.badge(target, w - 6, 2, model.status, model.status)
          ui.text(target, 2, 4, ("Total: %.0f"):format(model.payload.total_water or 0), colors.get("text"), colors.get("background"))
          ui.text(target, 2, 5, ("Target: %.0f"):format(config.target_volume or 0), colors.get("text"), colors.get("background"))
          ui.text(target, 2, 7, ("Master link: %s age:%s"):format(model.master_state, model.master_age), colors.get("text"), colors.get("background"))
        end },
        { name = "Details", render = function(target)
          local w, h = ui.getSize(target)
          if not w or not h then
            return
          end
          ui.panel(target, 1, 1, w, h, "WATER DETAILS", model.status)
          support_ui_pages.render_alert_banner(target, ui, model)
          local rows = {
            { text = ("Tanks: %d"):format(#(model.payload.buffers or {})) },
            { text = ("Registry total:%d bound:%d missing:%d"):format(model.summary.total or 0, model.summary.bound or 0, model.summary.missing or 0) },
            { text = ("Last scan: %s"):format(model.last_scan) }
          }
          ui.list(target, 2, 3, w - 2, rows, { max_rows = h - 4 })
        end },
        { name = "Diagnostics", render = function(target)
          local w, h = ui.getSize(target)
          if not w or not h then
            return
          end
          ui.panel(target, 1, 1, w, h, "WATER DIAGNOSTICS", model.status)
          support_ui_pages.render_alert_banner(target, ui, model)
          local rows = support_ui_pages.common_diagnostic_rows(model, devices.discovery_failed)
          support_ui_pages.append_local_alert_rows(rows, model.local_alerts)
          ui.list(target, 2, 3, w - 2, rows, { max_rows = h - 5 })
          support_ui_pages.render_log_mode_button(target, utils, 1, h - 1, w - 2)
        end,
        handle_touch = function(x, y)
          local w2, h2 = ui.getSize(mon)
          return support_ui_pages.handle_log_mode_touch(x, y, (h2 or 20) - 1, utils, 1)
        end }
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true }
    })
  end
  monitor_router:render(mon, model)
end

local function handle_monitor_touch(x, y)
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then
    return page.handle_touch(x, y)
  end
end

local function master_peer_state()
  return role_logic.master_peer_state(comms, constants.roles.MASTER)
end

local function is_master_connected()
  return role_logic.is_master_connected({
    comms = comms,
    master_role = constants.roles.MASTER,
    last_seen_ts = master_seen_ts,
    heartbeat_interval = config.heartbeat_interval
  })
end

local function handle_command(message)
  local command, parse_error = support_command_handler.parse_node_command(message, {
    protocol = protocol,
    comms = comms
  })
  if parse_error then
    return support_command_handler.finish_with_result(devices, parse_error)
  end
  if not command then
    return
  end
  return support_command_handler.reject_unsupported(devices)
end

local function init()
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
    heartbeat_state = function() return { tanks = #config.loop_tanks } end
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
  utils.log("WATER", "Node ready: " .. comms.network.id)
end

init()
services:add({
  name = "router_touch",
  tick = function(dt, event)
    if event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then
      handle_monitor_touch(event[3], event[4])
    end
  end
})

support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, balance_loop)
