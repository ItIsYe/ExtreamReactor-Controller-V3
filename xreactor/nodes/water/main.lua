-- CONFIG
local CONFIG = {
  LOG_NAME = "water", -- Log file name for this node.
  LOG_PREFIX = "WATER", -- Default log prefix for water events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_water.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
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
local network_lib = require("core.network")
local safety = require("core.safety")
local config = require("nodes.water.config")

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
local tanks = {}
local last_heartbeat = 0

local function cache()
  tanks = utils.cache_peripherals(config.loop_tanks)
end

local function hello()
  network:broadcast(protocol.hello(network.id, network.role, { tanks = #config.loop_tanks }))
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

local function send_status()
  local total, buffers = total_water()
  local payload = { total_water = total, buffers = buffers }
  network:send(constants.channels.STATUS, protocol.status(network.id, network.role, payload))
  last_heartbeat = os.epoch("utc")
end

local function main_loop()
  while true do
    balance_loop()
    if os.epoch("utc") - last_heartbeat > config.heartbeat_interval * 1000 then
      send_status()
    end
    local msg = network:receive(CONFIG.RECEIVE_TIMEOUT)
    if msg and msg.type == constants.message_types.HELLO then
      -- acknowledgement only
    end
  end
end

local function init()
  cache()
  network = network_lib.init(config)
  hello()
  send_status()
  utils.log("WATER", "Node ready: " .. network.id)
end

init()
main_loop()
