-- CONFIG
local CONFIG = {
  LOG_NAME = "fuel", -- Log file name for this node.
  LOG_PREFIX = "FUEL", -- Default log prefix for fuel events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")
local safety = require("core.safety")
local config = require("nodes.fuel.config")

-- Initialize file logging early to capture startup events.
local node_id = utils.read_node_id(CONFIG.NODE_ID_PATH)
local log_name = utils.build_log_name(CONFIG.LOG_NAME, node_id)
local debug_enabled = config.debug_logging
if CONFIG.DEBUG_LOG_ENABLED ~= nil then
  debug_enabled = CONFIG.DEBUG_LOG_ENABLED
end
utils.init_logger({ log_name = log_name, prefix = CONFIG.LOG_PREFIX, enabled = debug_enabled })
utils.log(CONFIG.LOG_PREFIX, "Startup", "INFO")

local network
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

local function hello()
  network:broadcast(protocol.hello(network.id, network.role, { reserve = reserve }))
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

local function send_status()
  local amount = enforce_reserve(read_fuel())
  local payload = { reserve = amount, minimum_reserve = reserve, sources = { { id = config.storage_bus or "unknown", amount = amount } } }
  network:send(constants.channels.STATUS, protocol.status(network.id, network.role, payload))
  last_heartbeat = os.epoch("utc")
end

local function handle_command(message)
  if not protocol.is_for_node(message, network.id) then return end
  local command = message.payload.command
  if not command then return end
  if command.target == constants.command_targets.SET_RESERVE then
    reserve = command.value
  elseif command.target == constants.command_targets.MODE and command.value == constants.node_states.MANUAL then
    -- manual mode acknowledged but not changing behavior
  end
  network:send(constants.channels.CONTROL, protocol.ack(network.id, network.role, command.command_id, "ack"))
end

local function main_loop()
  while true do
    if os.epoch("utc") - last_heartbeat > config.heartbeat_interval * 1000 then
      send_status()
    end
    local message = network:receive(CONFIG.RECEIVE_TIMEOUT)
    if message then
      if message.type == constants.message_types.COMMAND then
        handle_command(message)
      end
    end
  end
end

local function init()
  cache()
  network = network_lib.init(config)
  hello()
  send_status()
  utils.log("FUEL", "Node ready: " .. network.id)
end

init()
main_loop()
