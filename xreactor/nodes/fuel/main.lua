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
local registry_lib = require("core.registry")
local service_manager = require("services.service_manager")
local comms_service = require("services.comms_service")
local telemetry_service = require("services.telemetry_service")
local discovery_service = require("services.discovery_service")
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

local comms
local services
local registry = registry_lib.new({ node_id = node_id, role = "fuel", log_prefix = CONFIG.LOG_PREFIX })
local fuel_health = health.new({})
local storage
local last_heartbeat = 0
local reserve = config.minimum_reserve

local function cache()
  if config.storage_bus and peripheral.isPresent(config.storage_bus) then
    local wrapped, err = utils.safe_wrap(config.storage_bus)
    if wrapped then
      storage = wrapped
    else
      utils.log("FUEL", "WARN: storage bus wrap failed: " .. tostring(err))
    end
  end
end

local function discover()
  local devices = {}
  if config.storage_bus and peripheral.isPresent(config.storage_bus) then
    table.insert(devices, {
      name = config.storage_bus,
      type = peripheral.getType(config.storage_bus),
      methods = peripheral.getMethods(config.storage_bus) or {},
      kind = "storage"
    })
  end
  registry:sync(devices)
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
  fuel_health.status = next(reasons) and health.status.DEGRADED or health.status.OK
  fuel_health.reasons = reasons
  fuel_health.last_seen_ts = os.epoch("utc")
  fuel_health.bindings = { storage = has_storage and config.storage_bus or nil }
  fuel_health.capabilities = { storage = config.storage_bus ~= nil }
  local payload = {
    reserve = amount,
    minimum_reserve = reserve,
    sources = { { id = config.storage_bus or "unknown", amount = amount } },
    health = {
      status = fuel_health.status,
      reasons = health.reasons_list(fuel_health),
      last_seen_ts = fuel_health.last_seen_ts,
      bindings = fuel_health.bindings,
      capabilities = fuel_health.capabilities
    },
    bindings = fuel_health.bindings
  }
  return payload
end

local function handle_command(message)
  if not protocol.is_for_node(message, comms.network.id) then return end
  local command = message.payload.command
  if not command then return end
  if command.target == constants.command_targets.SET_RESERVE then
    reserve = command.value
  elseif command.target == constants.command_targets.MODE and command.value == constants.node_states.MANUAL then
    -- manual mode acknowledged but not changing behavior
  end
  comms:send_command_ack(message, "ack")
end

local function init()
  cache()
  services = service_manager.new({ log_prefix = "FUEL" })
  comms = comms_service.new({
    config = config,
    log_prefix = "FUEL",
    on_message = function(message)
      if message.type == "PROTO_MISMATCH" then
        fuel_health.status = health.status.DEGRADED
        fuel_health.reasons = { [health.reasons.PROTO_MISMATCH] = true }
        return
      end
      if message.type == constants.message_types.COMMAND then
        handle_command(message)
      end
    end
  })
  services:add(comms)
  services:add(discovery_service.new({
    registry = registry,
    discover = discover,
    interval = config.heartbeat_interval
  }))
  services:add(telemetry_service.new({
    comms = comms,
    status_interval = config.heartbeat_interval,
    heartbeat_interval = config.heartbeat_interval,
    build_payload = build_status_payload,
    heartbeat_state = function() return { reserve = reserve } end
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
    elseif event[1] == "timer" and event[2] == timer then
      break
    end
  end
  services:tick()
end
