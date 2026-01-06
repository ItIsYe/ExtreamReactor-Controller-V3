package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")
local config = require("nodes.reprocessor.config")

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
    local msg = network:receive(0.5)
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
