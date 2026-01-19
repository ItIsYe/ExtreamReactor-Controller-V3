-- CONFIG
local CONFIG = {
  LOG_NAME = "energy", -- Log file name for this node.
  LOG_PREFIX = "ENERGY", -- Default log prefix for energy events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_energy.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = "/xreactor/nodes/energy/config.lua", -- Config file path.
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "energy",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
local require = bootstrap.require
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")

local DEFAULT_CONFIG = {
  role = constants.roles.ENERGY_NODE, -- Node role identifier.
  node_id = "ENERGY-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor/logs/energy.log.
  wireless_modem = "right", -- Default wireless modem side.
  wired_modem = nil, -- Optional wired modem side.
  matrix = nil, -- Optional induction matrix peripheral name (legacy override).
  cubes = {}, -- Optional list of energy cube names (legacy override).
  scan_interval = 15, -- Seconds between peripheral discovery scans.
  monitor = {
    preferred_name = nil, -- Optional monitor name to pin (overrides auto-selection).
    strategy = "largest" -- "largest" or "first" when choosing among multiple monitors.
  },
  storage_filters = {
    include_names = nil, -- Optional allow-list; when set only these names are considered.
    exclude_names = {}, -- Optional deny-list of peripheral names to ignore.
    prefer_names = {} -- Optional names to prioritize in selection order.
  },
  heartbeat_interval = 2, -- Seconds between status heartbeats.
  channels = {
    control = constants.channels.CONTROL, -- Control channel for MASTER commands.
    status = constants.channels.STATUS -- Status channel for telemetry.
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
  if config_values.matrix ~= nil and type(config_values.matrix) ~= "string" then
    config_values.matrix = defaults.matrix
    add_config_warning("matrix invalid; defaulting to " .. tostring(defaults.matrix))
  end
  if type(config_values.cubes) ~= "table" then
    config_values.cubes = utils.deep_copy(defaults.cubes)
    add_config_warning("cubes missing/invalid; defaulting to configured list")
  end
  if type(config_values.scan_interval) ~= "number" or config_values.scan_interval <= 0 then
    config_values.scan_interval = defaults.scan_interval
    add_config_warning("scan_interval missing/invalid; defaulting to " .. tostring(defaults.scan_interval))
  end
  if type(config_values.monitor) ~= "table" then
    config_values.monitor = utils.deep_copy(defaults.monitor)
    add_config_warning("monitor config missing/invalid; defaulting to configured monitor options")
  end
  if config_values.monitor.preferred_name ~= nil and type(config_values.monitor.preferred_name) ~= "string" then
    config_values.monitor.preferred_name = defaults.monitor.preferred_name
    add_config_warning("monitor.preferred_name invalid; defaulting to configured value")
  end
  if type(config_values.monitor.strategy) ~= "string" then
    config_values.monitor.strategy = defaults.monitor.strategy
    add_config_warning("monitor.strategy invalid; defaulting to " .. tostring(defaults.monitor.strategy))
  end
  if type(config_values.storage_filters) ~= "table" then
    config_values.storage_filters = utils.deep_copy(defaults.storage_filters)
    add_config_warning("storage_filters missing/invalid; defaulting to configured filters")
  end
  if config_values.storage_filters.include_names ~= nil and type(config_values.storage_filters.include_names) ~= "table" then
    config_values.storage_filters.include_names = defaults.storage_filters.include_names
    add_config_warning("storage_filters.include_names invalid; defaulting to configured value")
  end
  if type(config_values.storage_filters.exclude_names) ~= "table" then
    config_values.storage_filters.exclude_names = utils.deep_copy(defaults.storage_filters.exclude_names)
    add_config_warning("storage_filters.exclude_names missing/invalid; defaulting to configured list")
  end
  if type(config_values.storage_filters.prefer_names) ~= "table" then
    config_values.storage_filters.prefer_names = utils.deep_copy(defaults.storage_filters.prefer_names)
    add_config_warning("storage_filters.prefer_names missing/invalid; defaulting to configured list")
  end
  if type(config_values.heartbeat_interval) ~= "number" or config_values.heartbeat_interval <= 0 then
    config_values.heartbeat_interval = defaults.heartbeat_interval
    add_config_warning("heartbeat_interval missing/invalid; defaulting to " .. tostring(defaults.heartbeat_interval))
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

local network
local devices = {
  storages = {},
  monitor = nil,
  monitor_name = nil,
  bound_storage_names = {},
  degraded_reason = nil,
  last_scan_ts = nil,
  last_scan_result = nil
}
local last_heartbeat = 0
local last_scan = 0

local function to_set(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[value] = true
  end
  return out
end

local function build_method_set(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    return {}
  end
  return to_set(methods)
end

local function resolve_storage_profile(methods)
  if methods.getEnergy and methods.getMaxEnergy then
    return { stored = "getEnergy", capacity = "getMaxEnergy", input = "getLastInput", output = "getLastOutput" }
  end
  if methods.getEnergyStored and methods.getMaxEnergyStored then
    return { stored = "getEnergyStored", capacity = "getMaxEnergyStored" }
  end
  if methods.getStoredPower and methods.getMaxStoredPower then
    return { stored = "getStoredPower", capacity = "getMaxStoredPower" }
  end
  return nil
end

local function is_blocked_type(name)
  local type_name = peripheral.getType(name)
  if not type_name then
    return false
  end
  type_name = tostring(type_name):lower()
  return type_name == "monitor" or type_name == "modem" or type_name == "peripheral_hub"
end

local function pick_monitor(names)
  if config.monitor and config.monitor.preferred_name then
    local preferred = config.monitor.preferred_name
    if peripheral.getType(preferred) == "monitor" then
      return preferred
    end
  end
  local candidates = {}
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      table.insert(candidates, name)
    end
  end
  if #candidates == 0 then
    return nil
  end
  if config.monitor and tostring(config.monitor.strategy):lower() == "first" then
    table.sort(candidates)
    return candidates[1]
  end
  local best_name, best_area
  for _, name in ipairs(candidates) do
    local mon = utils.safe_wrap(name)
    if mon and mon.getSize then
      local w, h = mon.getSize()
      local area = w * h
      if not best_area or area > best_area then
        best_area = area
        best_name = name
      end
    end
  end
  if best_name then
    return best_name
  end
  table.sort(candidates)
  return candidates[1]
end

local function log_discovery_snapshot(names, candidates, monitor_name)
  if not debug_enabled then
    return
  end
  utils.log("ENERGY", "Discovery snapshot: names=" .. textutils.serialize(names))
  for _, name in ipairs(names) do
    utils.log("ENERGY", ("Discovery peripheral: %s type=%s"):format(tostring(name), tostring(peripheral.getType(name))))
  end
  for _, candidate in ipairs(candidates) do
    utils.log("ENERGY", ("Discovery candidate: %s methods=%s"):format(tostring(candidate.name), textutils.serialize(candidate.methods)))
  end
  if monitor_name then
    utils.log("ENERGY", ("Discovery monitor selection: %s"):format(tostring(monitor_name)))
  end
end

local function discover()
  local names = peripheral.getNames() or {}
  local include_set = config.storage_filters and config.storage_filters.include_names and to_set(config.storage_filters.include_names) or nil
  local exclude_set = to_set(config.storage_filters and config.storage_filters.exclude_names or {})
  local prefer_names = {}
  for _, name in ipairs(config.storage_filters and config.storage_filters.prefer_names or {}) do
    table.insert(prefer_names, name)
  end
  if config.matrix then
    table.insert(prefer_names, config.matrix)
  end
  for _, name in ipairs(config.cubes or {}) do
    table.insert(prefer_names, name)
  end

  local monitor_name = pick_monitor(names)
  local monitor = monitor_name and utils.safe_wrap(monitor_name) or nil
  if monitor_name and not monitor then
    utils.log("ENERGY", "WARN: monitor wrap failed for " .. tostring(monitor_name))
  end

  local storages = {}
  local bound_names = {}
  local candidates = {}

  local function consider_name(name)
    if exclude_set[name] then
      return
    end
    if is_blocked_type(name) then
      return
    end
    if include_set and not include_set[name] then
      return
    end
    local methods = build_method_set(name)
    local profile = resolve_storage_profile(methods)
    if profile then
      table.insert(candidates, { name = name, profile = profile, methods = methods })
    end
  end

  for _, name in ipairs(names) do
    consider_name(name)
  end
  for _, name in ipairs(prefer_names) do
    if peripheral.isPresent(name) then
      consider_name(name)
    end
  end

  local seen = {}
  for _, candidate in ipairs(candidates) do
    if not seen[candidate.name] then
      seen[candidate.name] = true
      local wrapped = utils.safe_wrap(candidate.name)
      if wrapped then
        table.insert(storages, { name = candidate.name, profile = candidate.profile })
        table.insert(bound_names, candidate.name)
      end
    end
  end

  local degraded_reason
  if #names == 0 then
    degraded_reason = "no_peripherals"
  else
    local reasons = {}
    if not monitor then
      table.insert(reasons, "no_monitor")
    end
    if #storages == 0 then
      table.insert(reasons, "no_storage")
    end
    if #reasons > 0 then
      degraded_reason = table.concat(reasons, ",")
    end
  end

  devices.monitor = monitor
  devices.monitor_name = monitor_name
  devices.storages = storages
  devices.bound_storage_names = bound_names
  devices.degraded_reason = degraded_reason
  devices.last_scan_ts = os.epoch("utc")
  devices.last_scan_result = ("monitor=%s storages=%d"):format(monitor_name or "none", #storages)

  log_discovery_snapshot(names, candidates, monitor_name)
end

local function hello()
  network:broadcast(protocol.hello(network.id, network.role, {
    storages = #(devices.storages or {}),
    monitor = devices.monitor and 1 or 0
  }))
end

local function read_energy()
  local total, capacity, input, output = 0, 0, 0, 0
  local stores = {}
  for _, storage in ipairs(devices.storages or {}) do
    local profile = storage.profile or {}
    local function read_metric(method)
      if not method then
        return 0
      end
      local value = utils.safe_peripheral_call(storage.name, method)
      return tonumber(value) or 0
    end
    local stored = read_metric(profile.stored)
    local cap = read_metric(profile.capacity)
    local in_rate = read_metric(profile.input)
    local out_rate = read_metric(profile.output)
    stored = tonumber(stored) or 0
    cap = tonumber(cap) or stored
    in_rate = tonumber(in_rate) or 0
    out_rate = tonumber(out_rate) or 0
    total = total + stored
    capacity = capacity + cap
    input = input + in_rate
    output = output + out_rate
    table.insert(stores, { id = storage.name, stored = stored, capacity = cap, input = in_rate, output = out_rate })
  end
  return { stored = total, capacity = capacity, input = input, output = output, stores = stores }
end

local function send_status()
  local energy = read_energy()
  energy.monitor_bound = devices.monitor ~= nil
  energy.storage_bound_count = #(devices.storages or {})
  energy.bound_storage_names = devices.bound_storage_names or {}
  energy.degraded_reason = devices.degraded_reason
  if devices.degraded_reason then
    energy.status = constants.status_levels.WARNING
  else
    energy.status = constants.status_levels.OK
  end
  energy.last_scan_ts = devices.last_scan_ts
  energy.last_scan_result = devices.last_scan_result
  network:send(constants.channels.STATUS, protocol.status(network.id, network.role, energy))
  last_heartbeat = os.epoch("utc")
end

local function main_loop()
  while true do
    if os.epoch("utc") - last_scan > config.scan_interval * 1000 then
      discover()
      last_scan = os.epoch("utc")
    end
    if os.epoch("utc") - last_heartbeat > config.heartbeat_interval * 1000 then
      send_status()
    end
    local message = network:receive(CONFIG.RECEIVE_TIMEOUT)
    if message and message.type == constants.message_types.HELLO then
      -- master seen
    end
  end
end

local function init()
  discover()
  last_scan = os.epoch("utc")
  network = network_lib.init(config)
  hello()
  send_status()
  utils.log("ENERGY", "Node ready: " .. network.id)
end

init()
main_loop()
