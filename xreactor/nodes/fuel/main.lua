package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")
local safety = require("core.safety")
local config = require("nodes.fuel.config")

local network
local storage
local last_heartbeat = 0
local reserve = config.minimum_reserve

local function cache()
  if config.storage_bus and peripheral.isPresent(config.storage_bus) then
    storage = peripheral.wrap(config.storage_bus)
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
    local message = network:receive(0.5)
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
