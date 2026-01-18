-- CONFIG
local CONFIG = {
  LOG_NAME = "reprocessor", -- Log file name for this node.
  LOG_PREFIX = "REPROC", -- Default log prefix for reprocessor events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_reprocessor.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  CONFIG_PATH = "/xreactor/nodes/reprocessor/config.lua", -- Config file path.
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "reprocessor",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
local require = bootstrap.require
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")

local DEFAULT_CONFIG = {
  role = constants.roles.REPROCESSOR_NODE, -- Node role identifier.
  node_id = "REPROC-1", -- Default node_id used if none is set.
  debug_logging = false, -- Enable debug logging to /xreactor/logs/reprocessor.log.
  wireless_modem = "right", -- Default wireless modem side.
  wired_modem = nil, -- Optional wired modem side.
  buffers = { "chemical_tank_0" }, -- Default buffer peripheral names.
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
  if type(config_values.buffers) ~= "table" then
    config_values.buffers = utils.deep_copy(defaults.buffers)
    add_config_warning("buffers missing/invalid; defaulting to configured list")
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
local buffers = {}
local last_heartbeat = 0
local master_seen = os.epoch("utc")
local standby = false

local function cache()
  buffers = utils.cache_peripherals(config.buffers)
end

local function hello()
  network:broadcast(protocol.hello(network.id, network.role, { buffers = #config.buffers }))
end

local function read_buffers()
  local info = {}
  for name, buf in pairs(buffers) do
    local stored = 0
    if buf.getWaste then
      stored = buf.getWaste()
    elseif buf.getItemCount then
      stored = buf.getItemCount()
    end
    table.insert(info, { id = name, stored = stored })
  end
  return info
end

local function send_status()
  local payload = { buffers = read_buffers(), standby = standby }
  network:send(constants.channels.STATUS, protocol.status(network.id, network.role, payload))
  last_heartbeat = os.epoch("utc")
end

local function process_buffers()
  if standby then return end
  for _, buf in pairs(buffers) do
    if buf.process then
      pcall(buf.process)
    end
  end
end

local function main_loop()
  while true do
    process_buffers()
    if os.epoch("utc") - last_heartbeat > config.heartbeat_interval * 1000 then
      send_status()
    end
    if os.epoch("utc") - master_seen > config.heartbeat_interval * 6000 then
      standby = true
    end
    local msg = network:receive(CONFIG.RECEIVE_TIMEOUT)
    if msg then
      if msg.type == constants.message_types.HELLO then
        master_seen = os.epoch("utc")
        standby = false
      elseif msg.type == constants.message_types.COMMAND and protocol.is_for_node(msg, network.id) then
        local cmd = msg.payload.command
        if cmd.target == constants.command_targets.MODE and cmd.value == constants.node_states.OFF then
          standby = true
        elseif cmd.target == constants.command_targets.MODE and cmd.value == constants.node_states.RUNNING then
          standby = false
        end
        network:send(constants.channels.CONTROL, protocol.ack(network.id, network.role, cmd.command_id, "ack"))
      end
    end
  end
end

local function init()
  cache()
  network = network_lib.init(config)
  hello()
  send_status()
  utils.log("REPROC", "Node ready: " .. network.id)
end

init()
main_loop()
