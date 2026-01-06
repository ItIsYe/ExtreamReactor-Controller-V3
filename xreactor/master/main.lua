package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local constants = require("shared.constants")
local colors = require("shared.colors")
local protocol = require("core.protocol")
local utils = require("core.utils")
local network_lib = require("core.network")
local sequencer_lib = require("master.startup_sequencer")
local overview_ui = require("master.ui.overview")
local rt_ui = require("master.ui.rt_dashboard")
local energy_ui = require("master.ui.energy")
local resources_ui = require("master.ui.resources")
local alarms_ui = require("master.ui.alarms")
local ui = require("core.ui")
local config = require("master.config")

local monitor_roles = {
  OVERVIEW = {},
  RT = {},
  ENERGY = {},
  RESOURCES = {},
  ALARMS = {}
}
local monitor_cache = {}
local nodes = {}
local alarms = {}
local power_target = 0
local sequencer
local network
local last_draw = 0
local monitor_scan_last = 0

local function discover_monitors()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      table.insert(names, name)
    end
  end
  table.sort(names)
  local monitors = {}
  for _, name in ipairs(names) do
    local mon = peripheral.wrap(name)
    if mon then
      ui.setScale(mon, config.ui_scale_default or 0.5)
      table.insert(monitors, { name = name, mon = mon })
    end
  end
  return monitors
end

local function assign_roles(monitors)
  for k in pairs(monitor_roles) do monitor_roles[k] = {} end
  if #monitors == 0 then return end
  local map = {
    "OVERVIEW",
    "RT",
    "ENERGY",
    "RESOURCES",
    "ALARMS"
  }
  for idx, entry in ipairs(monitors) do
    local role = map[math.min(idx, #map)] or "OVERVIEW"
    if idx > #map and #monitors >= 5 then role = "OVERVIEW" end
    monitor_roles[role] = monitor_roles[role] or {}
    table.insert(monitor_roles[role], entry)
  end
end

local function refresh_monitors(force)
  local now = os.epoch("utc")
  if not force and now - monitor_scan_last < 5000 then return end
  monitor_scan_last = now
  local monitors = discover_monitors()
  local signature = textutils.serialize(monitors)
  if monitor_cache.signature ~= signature or force then
    monitor_cache = { list = monitors, signature = signature }
    assign_roles(monitors)
    for _, roleList in pairs(monitor_roles) do
      for _, entry in ipairs(roleList) do
        ui.clear(entry.mon)
      end
    end
  end
end

local function add_alarm(sender, severity, message)
  table.insert(alarms, 1, {
    sender_id = sender,
    severity = severity,
    message = message,
    timestamp = textutils.formatTime(os.time(), true)
  })
  if #alarms > 50 then table.remove(alarms) end
end

local function update_node(message)
  local id = message.sender_id
  nodes[id] = nodes[id] or { id = id, role = message.role, status = constants.status_levels.OFFLINE }
  nodes[id].last_seen = os.epoch("utc")
  if message.type == constants.message_types.HELLO then
    nodes[id].status = constants.status_levels.OK
    nodes[id].state = constants.node_states.OFF
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
    sequencer:notify_ack(id, message.payload and message.payload.module_id)
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

local function draw()
  local now = os.epoch("utc")
  if now - last_draw < 400 then return end
  last_draw = now
  local overview_data = { nodes = {}, power_target = power_target, alarms = alarms }
  local rt_data = { rt_nodes = {}, ramp_profile = sequencer.ramp_profile, sequence_state = sequencer.state, queue = sequencer.queue }
  local energy_data = { stored = 0, capacity = 0, input = 0, output = 0, stores = {} }
  local resource_data = { fuel = { reserve = 0, minimum = 0, sources = {} }, water = { total = 0, buffers = {} }, reprocessor = {} }

  for _, node in pairs(nodes) do
    table.insert(overview_data.nodes, { id = node.id, role = node.role, status = node.status or constants.status_levels.OFFLINE })
    if node.role == constants.roles.RT_NODE then
      table.insert(rt_data.rt_nodes, { id = node.id, state = node.state or constants.node_states.OFF, output = node.output, modules = node.modules or {}, limits = node.limits })
    elseif node.role == constants.roles.ENERGY_NODE and node.capacity then
      energy_data.stored = energy_data.stored + (node.stored or 0)
      energy_data.capacity = energy_data.capacity + (node.capacity or 0)
      energy_data.input = energy_data.input + (node.input or 0)
      energy_data.output = energy_data.output + (node.output or 0)
      table.insert(energy_data.stores, { id = node.id, stored = node.stored, capacity = node.capacity, input = node.input, output = node.output })
    elseif node.role == constants.roles.FUEL_NODE then
      resource_data.fuel.reserve = node.reserve or resource_data.fuel.reserve
      resource_data.fuel.minimum = node.minimum_reserve or resource_data.fuel.minimum
      resource_data.fuel.sources = node.sources or resource_data.fuel.sources
    elseif node.role == constants.roles.WATER_NODE then
      resource_data.water.total = node.total_water or resource_data.water.total
      resource_data.water.buffers = node.buffers or resource_data.water.buffers
      resource_data.water.state = node.state
    elseif node.role == constants.roles.REPROCESSOR_NODE then
      resource_data.reprocessor = node.reprocessor or {}
    end
  end

  local function render(role, drawer, model)
    for _, entry in ipairs(monitor_roles[role] or {}) do
      drawer.render(entry.mon, model)
    end
  end

  render("OVERVIEW", overview_ui, overview_data)
  render("RT", rt_ui, rt_data)
  render("ENERGY", energy_ui, energy_data)
  render("RESOURCES", resources_ui, resource_data)
  render("ALARMS", alarms_ui, alarms)
end

local function init()
  refresh_monitors(true)
  network = network_lib.init(config)
  sequencer = sequencer_lib.new(network, config.startup_ramp)
  network:broadcast(protocol.hello(network.id, network.role, { monitors = monitor_cache.list and #monitor_cache.list or 0 }))
  utils.log("MASTER", "Initialized as " .. network.id)
end

local function main_loop()
  while true do
    refresh_monitors(false)
    sequencer:tick(nodes)
    check_timeouts()
    draw()
    local message = network:receive(0.5)
    if message then
      update_node(message)
    end
  end
end

init()
main_loop()
