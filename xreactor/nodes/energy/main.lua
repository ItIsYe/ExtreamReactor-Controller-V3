-- CONFIG
local CONFIG = {
  LOG_NAME = "energy", -- Log file name for this node.
  LOG_PREFIX = "ENERGY", -- Default log prefix for energy events.
  DEBUG_LOG_ENABLED = nil, -- Override debug logging (nil uses config value).
  BOOTSTRAP_LOG_ENABLED = false, -- Enable bootstrap loader debug log.
  BOOTSTRAP_LOG_PATH = nil, -- Optional override for loader log file (default: /xreactor_logs/loader_energy.log).
  NODE_ID_PATH = "/xreactor/config/node_id.txt", -- Node ID storage path.
  RECEIVE_TIMEOUT = 0.5 -- Network receive timeout (seconds).
}

local bootstrap = dofile("/xreactor/core/bootstrap.lua")
bootstrap.setup({
  role = "energy",
  log_enabled = CONFIG.BOOTSTRAP_LOG_ENABLED,
  log_path = CONFIG.BOOTSTRAP_LOG_PATH
})
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")
local config = require("nodes.energy.config")

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
local devices = {}
local last_heartbeat = 0

local function cache()
  devices.cubes = utils.cache_peripherals(config.cubes)
  if config.matrix and peripheral.isPresent(config.matrix) then
    local wrapped, err = utils.safe_wrap(config.matrix)
    if wrapped then
      devices.matrix = wrapped
    else
      utils.log("ENERGY", "WARN: matrix wrap failed: " .. tostring(err))
    end
  end
end

local function hello()
  network:broadcast(protocol.hello(network.id, network.role, { cubes = #config.cubes, matrix = config.matrix and 1 or 0 }))
end

local function read_energy()
  local total, capacity, input, output = 0, 0, 0, 0
  local stores = {}
  for name, cube in pairs(devices.cubes) do
    local stored = cube.getEnergy and cube.getEnergy() or 0
    local cap = cube.getMaxEnergy and cube.getMaxEnergy() or stored
    local in_rate = cube.getLastInput and cube.getLastInput() or 0
    local out_rate = cube.getLastOutput and cube.getLastOutput() or 0
    total = total + stored
    capacity = capacity + cap
    input = input + in_rate
    output = output + out_rate
    table.insert(stores, { id = name, stored = stored, capacity = cap })
  end
  if devices.matrix then
    local stored = devices.matrix.getEnergy and devices.matrix.getEnergy() or 0
    local cap = devices.matrix.getMaxEnergy and devices.matrix.getMaxEnergy() or stored
    total = total + stored
    capacity = capacity + cap
    table.insert(stores, { id = "matrix", stored = stored, capacity = cap })
  end
  return { stored = total, capacity = capacity, input = input, output = output, stores = stores }
end

local function send_status()
  local energy = read_energy()
  network:send(constants.channels.STATUS, protocol.status(network.id, network.role, energy))
  last_heartbeat = os.epoch("utc")
end

local function main_loop()
  while true do
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
  cache()
  network = network_lib.init(config)
  hello()
  send_status()
  utils.log("ENERGY", "Node ready: " .. network.id)
end

init()
main_loop()
