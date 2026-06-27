-- CONFIG
local CONFIG = {
  LOG_NAME = "reprocessor", -- Log file name for this node.
  LOG_PREFIX = "REPROC", -- Default log prefix for reprocessor events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_reprocessor.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = nil, -- Config file path (provided by role descriptor).
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "reprocessor",
  log_enabled = false,  -- kein lokales Log auf Node-Disk
  log_path = nil  -- kein lokales Log auf Node-Disk
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
local non_rt_payload = require("core.non_rt_payload")
local support_discovery = require("nodes.support.discovery")
local support_runtime = require("nodes.support.runtime")
local role_logic = require("nodes.support.role_logic")
local support_ui_pages = require("nodes.support.ui_pages")
local support_command_handler = require("nodes.support.command_handler")
local role_descriptor = require("nodes.reprocessor.role_descriptor")
local config_normalizer = require("nodes.reprocessor.config_normalizer")
local redstone_router_lib = require("nodes.fuel.redstone_router")
local router_ui_lib       = require("nodes.fuel.router_ui")
local feed_router_lib     = require("nodes.reprocessor.feed_router")

local DEFAULT_CONFIG = {
  role = constants.roles.REPROCESSOR_NODE, -- Node role identifier.
  node_id = "REPROC-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor_logs/reprocessor.log.
  reset_log_on_start = true, -- Truncate runtime log at startup to keep disk usage bounded.
  wireless_modem = nil, -- Autodetect wireless modem unless explicitly configured.
  wired_modem = nil, -- Optional wired modem side.
  buffers = { "chemical_tank_0" }, -- Default buffer peripheral names.
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
local reproc_health = health.new({})
local buffers = {}
local router
local rs_router
local router_ui_instance
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
local master_seen = os.epoch("utc")
local standby = false
local monitor_router = nil

local function warn_once(key, message)
  support_runtime.warn_once(devices, function(msg, level)
    utils.log(CONFIG.LOG_PREFIX, msg, level)
  end, key, message)
end

local function master_peer_state()
  return role_logic.master_peer_state(comms, constants.roles.MASTER)
end

local function is_master_connected()
  return role_logic.is_master_connected({
    comms = comms,
    master_role = constants.roles.MASTER,
    last_seen_ts = master_seen,
    heartbeat_interval = config.heartbeat_interval
  })
end

local function cache(bound_names)
  buffers = utils.cache_peripherals(bound_names or {})
end

local function discover()
  local names
  local registry_devices
  local allow_set = {}
  for _, name in ipairs(config.buffers or {}) do
    allow_set[name] = true
  end
  local allow_all = #config.buffers == 0
  local monitor_entry = monitor_adapter.find(nil, "first", 0.5, CONFIG.LOG_PREFIX)
  local monitor_name = monitor_entry and monitor_entry.name or nil
  devices.monitor = monitor_entry and monitor_entry.mon or nil
  devices.monitor_name = monitor_name
  -- Fallback: if no external monitor peripheral is attached, render to the
  -- computer's own terminal so Diagnostics/Router pages (including the
  -- log mode buttons) are visible on the PC console.
  if not devices.monitor and term and type(term.current) == "function" then
    devices.monitor = term.current()
    devices.monitor_name = devices.monitor_name or "term"
    devices.monitor_is_term = true
  end

  registry_devices, names = support_discovery.collect_monitor_device(utils, monitor_name)

  local buffer_devices = support_discovery.collect_devices_by_methods(names, {
    kind = "buffer",
    allow_name = function(name)
      return allow_all or allow_set[name]
    end,
    match = function(method_set)
      return (method_set.list and method_set.size) or method_set.getWaste or method_set.getItemCount
    end
  })
  for _, entry in ipairs(buffer_devices) do
    table.insert(registry_devices, entry)
  end
  registry:sync(registry_devices)
  devices.registry_summary = registry:get_summary()
  devices.registry_load_error = registry.state.load_error
  devices.last_scan_ts = os.epoch("utc")
  local bound = registry:get_bound_devices("buffer")
  local bound_names = {}
  for _, entry in ipairs(bound) do
    table.insert(bound_names, entry.name)
  end
  cache(bound_names)
end

local function hello()
  local summary = registry:get_summary()
  comms:send_hello({ buffers = summary.kinds.buffer and summary.kinds.buffer.bound or 0 })
end

-- P2 Fix: Kapazität pro Buffer lesen (zusätzlich zu stored) damit Master/UI
-- den Füllstand als Prozent anzeigen können, nicht nur die absolute Zahl.
local function read_buffer_capacity(buf)
  if buf.size then
    local ok, value = support_runtime.safe_wrapped_call(buf, "size")
    if ok and type(value) == "number" then return value end
  end
  if buf.getSize then
    local ok, value = support_runtime.safe_wrapped_call(buf, "getSize")
    if ok and type(value) == "number" then return value end
  end
  if buf.getCapacity then
    local ok, value = support_runtime.safe_wrapped_call(buf, "getCapacity")
    if ok and type(value) == "number" then return value end
  end
  if buf.getMaxWaste then
    local ok, value = support_runtime.safe_wrapped_call(buf, "getMaxWaste")
    if ok and type(value) == "number" then return value end
  end
  return nil
end

local function read_buffers()
  local info = {}
  for name, buf in pairs(buffers) do
    local stored = 0
    if buf.list and buf.size then
      local ok, items = support_runtime.safe_wrapped_call(buf, "list")
      if ok and type(items) == "table" then
        for _, stack in pairs(items) do
          if type(stack) == "table" and type(stack.count) == "number" then
            stored = stored + stack.count
          end
        end
      elseif not ok then
        warn_once("buffer_read:" .. tostring(name), "Buffer read failed for " .. tostring(name) .. ": " .. tostring(items))
      end
    elseif buf.getWaste then
      local ok, value = support_runtime.safe_wrapped_call(buf, "getWaste")
      if ok and type(value) == "number" then
        stored = value
      elseif not ok then
        warn_once("buffer_read:" .. tostring(name), "Buffer read failed for " .. tostring(name) .. ": " .. tostring(value))
      end
    elseif buf.getItemCount then
      local ok, value = support_runtime.safe_wrapped_call(buf, "getItemCount")
      if ok and type(value) == "number" then
        stored = value
      elseif not ok then
        warn_once("buffer_read:" .. tostring(name), "Buffer read failed for " .. tostring(name) .. ": " .. tostring(value))
      end
    end
    local capacity = read_buffer_capacity(buf)
    local percent = (capacity and capacity > 0) and math.floor(stored / capacity * 1000 + 0.5) / 10 or nil
    table.insert(info, { id = name, stored = stored, capacity = capacity, percent = percent })
  end
  return info
end

local get_feed_router
local process_state = {}

local function build_status_payload()
  local reasons = {}
  if not next(buffers) then
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
  reproc_health.status = next(reasons) and health.status.DEGRADED or health.status.OK
  reproc_health.reasons = reasons
  reproc_health.last_seen_ts = os.epoch("utc")
  reproc_health.bindings = { buffers = #read_buffers() }
  reproc_health.capabilities = { buffers = #config.buffers }
  local payload = non_rt_payload.build_base({
    ts = os.epoch("utc"),
    role = config.role,
    node_id = config.node_id,
    health = {
      status = reproc_health.status,
      reasons = health.reasons_list(reproc_health),
      last_seen_ts = reproc_health.last_seen_ts,
      bindings = reproc_health.bindings,
      capabilities = reproc_health.capabilities
    },
    discovery_failed = devices.discovery_failed,
    master_connected = master_ok,
    master_seen_s = master_seen and math.max(0, math.floor((os.epoch("utc") - master_seen) / 1000)) or nil,
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
  payload.buffers = read_buffers()
  -- P4: process()-Status pro Buffer im Payload mitgeben (ok/error/unsupported)
  for _, entry in ipairs(payload.buffers) do
    entry.process_state = process_state[entry.id]
  end
  payload.standby = standby
  payload.feed = get_feed_router():get_summary()
  payload.bindings = reproc_health.bindings
  payload.bindings_summary = health.summarize_bindings(reproc_health.bindings)
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
          ui.panel(target, 1, 1, w, h, "REPROC NODE", model.status)
          support_ui_pages.render_alert_banner(target, ui, model)
          ui.text(target, 2, 2, ("ID: %s"):format(model.node_id or "UNKNOWN"), colors.get("text"), colors.get("background"))
          ui.badge(target, w - 6, 2, model.status, model.status)
          ui.text(target, 2, 4, ("Standby: %s"):format(standby and "yes" or "no"), colors.get("text"), colors.get("background"))
          ui.text(target, 2, 6, ("Master link: %s age:%s"):format(model.master_state, model.master_age), colors.get("text"), colors.get("background"))
        end },
        { name = "Details", render = function(target)
          local w, h = ui.getSize(target)
          if not w or not h then
            return
          end
          ui.panel(target, 1, 1, w, h, "REPROC DETAILS", model.status)
          support_ui_pages.render_alert_banner(target, ui, model)
          local rows = {
            { text = ("Buffers: %d"):format(#(model.payload.buffers or {})) },
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
          ui.panel(target, 1, 1, w, h, "REPROC DIAGNOSTICS", model.status)
          support_ui_pages.render_alert_banner(target, ui, model)
          local rows = support_ui_pages.common_diagnostic_rows(model, devices.discovery_failed)
          support_ui_pages.append_local_alert_rows(rows, model.local_alerts)
          ui.list(target, 2, 3, w - 2, rows, { max_rows = h - 5 })
          -- Log mode buttons on bottom line
          support_ui_pages.render_log_mode_button(target, utils, 1, h - 1, w - 2)
        end,
        handle_touch = function(x, y)
          local w2, h2 = ui.getSize(mon)
          return support_ui_pages.handle_log_mode_touch(x, y, (h2 or 20) - 1, utils, 1)
        end },
        { name = "Router", render = function(target)
          get_router_ui():render(target, ui, colors)
        end,
        handle_touch = function(x, y)
          return get_router_ui():handle_touch(x, y)
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

-- P4 Fix: process()-Aufrufe protokollieren (Erfolg/Fehler/nicht vorhanden)
-- damit erkennbar ist ob die Wiederaufbereitung tatsächlich läuft.  -- { [name] = "ok" | "error" | "unsupported" }

local function process_buffers()
  if standby then return end
  for name, buf in pairs(buffers) do
    if buf.process then
      local ok, err = pcall(buf.process)
      local prev = process_state[name]
      if ok then
        if prev ~= "ok" then
          utils.log("REPROC", "process() OK for " .. tostring(name))
        end
        process_state[name] = "ok"
      else
        if prev ~= "error" then
          utils.log("REPROC", "process() failed for " .. tostring(name) .. ": " .. tostring(err), "WARN")
        end
        process_state[name] = "error"
      end
    else
      if process_state[name] ~= "unsupported" then
        warn_once("no_process:" .. tostring(name),
          "Buffer " .. tostring(name) .. " has no process() method — not a reprocessor port")
      end
      process_state[name] = "unsupported"
    end
  end
end

local function get_rs_router()
  if not rs_router then
    rs_router = redstone_router_lib.new({
      config    = config,
      log       = function(level, msg) utils.log("REPROC", msg, level) end,
      warn_once = function(key, msg) warn_once(key, msg) end,
    })
  end
  return rs_router
end

get_feed_router = function()
  if not router then
    router = feed_router_lib.new({
      config    = config,
      log       = function(level, msg) utils.log("REPROC", msg, level) end,
      warn_once = function(key, msg) warn_once(key, msg) end,
      rs_router = get_rs_router(),  -- share rs_router with router_ui
    })
  end
  return router
end

local function get_router_ui()
  if not router_ui_instance then
    router_ui_instance = router_ui_lib.new({
      redstone_router = get_rs_router(),
      config_path     = "/xreactor/config/reproc_routes.lua",
      log             = function(level, msg) utils.log("REPROC", msg, level) end,
      get_reactors    = function()
        local list, seen = {}, {}
        local fd = config.feed or {}
        for _, entry in ipairs(fd.targets or {}) do
          local label = entry.label or entry.inlet or "?"
          local id    = entry.label or label
          if not seen[id] then
            seen[id] = true
            list[#list + 1] = { id = id, label = label }
          end
        end
        if #list == 0 then
          for _, name in ipairs(peripheral.getNames() or {}) do
            local ptype = tostring(peripheral.getType(name) or ""):lower()
            if ptype:find("reprocessor") or name:lower():find("reprocessor") then
              if not seen[name] then
                seen[name] = true
                list[#list + 1] = { id = name, label = name }
              end
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
  local cmd, parse_error = support_command_handler.parse_node_command(message, {
    protocol = protocol,
    comms = comms
  })
  if parse_error then
    return support_command_handler.finish_with_result(devices, parse_error)
  end
  if not cmd then
    return
  end

  if cmd.target == constants.command_targets.MODE and cmd.value == constants.node_states.OFF then
    standby = true
  elseif cmd.target == constants.command_targets.MODE and cmd.value == constants.node_states.RUNNING then
    standby = false
  else
    return support_command_handler.reject_unsupported(devices)
  end
  return support_command_handler.finish(devices, true)
end

local function init()
  services = service_manager.new({ log_prefix = "REPROC" })
  comms = comms_service.new({
    config = config,
    log_prefix = "REPROC",
    on_command = handle_command,
    on_message = function(message)
      if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then
        devices.proto_mismatch = true
        return
      end
      if message.role == constants.roles.MASTER then
        master_seen = os.epoch("utc")
        if message.type == constants.message_types.STATUS and message.payload and message.payload.alerts then
          master_alerts = message.payload.alerts
        end
      end
      if message.type == constants.message_types.HELLO then
        standby = false
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
    heartbeat_state = function() return { standby = standby } end
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
        standby = standby,
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
  utils.log("REPROC", "Node ready: " .. comms.network.id)
end

init()
services:add({
  name = "router_touch",
  tick = function(dt, event)
    -- monitor_touch: external Monitor peripheral touch
    -- mouse_click: Advanced Computer's own terminal (when monitor falls back to term)
    if event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then
      handle_monitor_touch(event[3], event[4])
    end
  end
})

support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function()
  process_buffers()
  -- P1 Fix: Logistics-Router pausiert ebenfalls im Standby, nicht nur process_buffers().
  -- Vorher lief der Router weiter und transportierte Abfall obwohl MODE OFF gesetzt war.
  if not standby then
    get_feed_router():tick()
  end
  -- rs_router peripherals are refreshed via route_and_act in the logistics cycle
  if os.epoch("utc") - master_seen > config.heartbeat_interval * 6000 then
    standby = true
  end
end)
