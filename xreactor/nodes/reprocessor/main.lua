-- CONFIG
local CONFIG = {
  LOG_NAME = "reprocessor", -- Log file name for this node.
  LOG_PREFIX = "REPROC", -- Default log prefix for reprocessor events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup()
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")
local config = require("nodes.reprocessor.config")

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
