package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")
local sequencer_lib = require("master.startup_sequencer")
local overview_ui = require("master.ui.overview")
local rt_ui = require("master.ui.rt_dashboard")
local energy_ui = require("master.ui.energy")
local resources_ui = require("master.ui.resources")
local alarms_ui = require("master.ui.alarms")

local config = require("master.config")

local monitors = {}
local nodes = {}
local alarms = {}
local power_target = 0
local sequencer
local network
local last_draw = 0

local function setup_monitors()
  monitors = {}
  for _, side in ipairs(config.monitors) do
    if peripheral.isPresent(side) then
      local mon = peripheral.wrap(side)
      mon.setTextScale(0.5)
      table.insert(monitors, mon)
    end
  end
end

local function add_alarm(sender, severity, message)
  table.insert(alarms, {
    sender_id = sender,
    severity = severity,
    message = message,
    timestamp = textutils.formatTime(os.time(), true)
  })
end

local function update_node(message)
  local id = message.sender_id
  nodes[id] = nodes[id] or { id = id, role = message.role, status = constants.status_levels.OFFLINE }
  nodes[id].last_seen = os.epoch("utc")
  if message.type == constants.message_types.HELLO then
    nodes[id].status = constants.status_levels.OK
    nodes[id].state = constants.node_states.OFF
    if message.payload and message.payload.capabilities then
      nodes[id].capabilities = message.payload.capabilities
    end
    if message.role == constants.roles.RT_NODE then
      sequencer:enqueue(id)
    end
  elseif message.type == constants.message_types.HEARTBEAT then
    nodes[id].state = message.payload.state
  elseif message.type == constants.message_types.STATUS then
    nodes[id] = utils.merge(nodes[id], message.payload)
    nodes[id].status = message.payload.status or nodes[id].status
    if nodes[id].state == constants.node_states.RUNNING then
      sequencer:notify_stable(id)
    end
  elseif message.type == constants.message_types.ACK then
    sequencer:notify_ack(id)
  elseif message.type == constants.message_types.ALERT then
    add_alarm(id, message.payload.severity, message.payload.message)
  end
end

local function check_timeouts()
  for _, node in pairs(nodes) do
    if node.last_seen and (os.epoch("utc") - node.last_seen > config.heartbeat_interval * 4000) then
      node.status = constants.status_levels.OFFLINE
    end
  end
end

local function dispatch_command(node_id, target, value)
  local cmd = { target = target, value = value }
  network:send(constants.channels.CONTROL, protocol.command(network.id, network.role, node_id, cmd))
end

local function decide_power()
  local total_output = 0
  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE and node.output then
      total_output = total_output + node.output
    end
  end
  if total_output < power_target then
    for _, node in pairs(nodes) do
      if node.role == constants.roles.RT_NODE then
        dispatch_command(node.id, constants.command_targets.POWER_TARGET, power_target / math.max(1, #nodes))
      end
    end
  end
end

local function draw()
  local now = os.epoch("utc")
  if now - last_draw < 2000 then return end
  last_draw = now
  local overview_data = { nodes = {}, power_target = power_target }
  local rt_data = { rt_nodes = {}, ramp_profile = sequencer.ramp_profile, sequence_state = sequencer.state }
  local energy_data = { stored = 0, capacity = 0, input = 0, output = 0, stores = {} }
  local resource_data = { fuel = { reserve = 0, minimum = 0, sources = {} }, water = { total = 0, buffers = {} } }

  for _, node in pairs(nodes) do
    table.insert(overview_data.nodes, { id = node.id, role = node.role, status = node.status or constants.status_levels.OFFLINE })
    if node.role == constants.roles.RT_NODE then
      table.insert(rt_data.rt_nodes, { id = node.id, state = node.state or constants.node_states.OFF, output = node.output, turbine_rpm = node.turbine_rpm, steam = node.steam })
    elseif node.role == constants.roles.ENERGY_NODE and node.capacity then
      energy_data.stored = energy_data.stored + (node.stored or 0)
      energy_data.capacity = energy_data.capacity + (node.capacity or 0)
      energy_data.input = energy_data.input + (node.input or 0)
      energy_data.output = energy_data.output + (node.output or 0)
      table.insert(energy_data.stores, { id = node.id, stored = node.stored, capacity = node.capacity })
    elseif node.role == constants.roles.FUEL_NODE then
      resource_data.fuel.reserve = node.reserve or resource_data.fuel.reserve
      resource_data.fuel.minimum = node.minimum_reserve or resource_data.fuel.minimum
      resource_data.fuel.sources = node.sources or resource_data.fuel.sources
    elseif node.role == constants.roles.WATER_NODE then
      resource_data.water.total = node.total_water or resource_data.water.total
      resource_data.water.buffers = node.buffers or resource_data.water.buffers
    end
  end

  if monitors[1] then overview_ui.draw({ monitors[1] }, overview_data) end
  if monitors[2] then rt_ui.draw({ monitors[2] }, rt_data) end
  if monitors[3] then energy_ui.draw({ monitors[3] }, energy_data) end
  if monitors[4] then resources_ui.draw({ monitors[4] }, resource_data) end
  if monitors[5] then alarms_ui.draw({ monitors[5] }, alarms) end
end

local function init()
  setup_monitors()
  network = network_lib.init(config)
  sequencer = sequencer_lib.new(network, config.startup_ramp)
  network:broadcast(protocol.hello(network.id, network.role, { monitors = #monitors }))
  utils.log("MASTER", "Initialized as " .. network.id)
end

local function main_loop()
  while true do
    sequencer:tick()
    check_timeouts()
    decide_power()
    draw()
    local message = network:receive(0.5)
    if message and protocol.is_for_node(message, network.id) then
      update_node(message)
    elseif message then
      update_node(message)
    end
  end
end

init()
main_loop()
