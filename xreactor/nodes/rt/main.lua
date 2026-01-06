package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local safety = require("core.safety")
local network_lib = require("core.network")
local machine = require("core.state_machine")
local config = require("nodes.rt.config")

local network
local peripherals = {}
local targets = { power = 0, steam = 0, rpm = 0 }
local current_state
local master_seen = os.epoch("utc")
local last_heartbeat = 0

local function cache()
  peripherals.reactors = utils.cache_peripherals(config.reactors)
  peripherals.turbines = utils.cache_peripherals(config.turbines)
  if config.steam_buffer and peripheral.isPresent(config.steam_buffer) then
    peripherals.steam_buffer = peripheral.wrap(config.steam_buffer)
  end
end

local function add_alarm(sender, severity, message)
  network:send(constants.channels.CONTROL, protocol.alert(sender, config.role, severity, message))
end

local function broadcast_status(status_level)
  local payload = {
    status = status_level,
    state = current_state.state(),
    output = targets.power,
    turbine_rpm = targets.rpm,
    steam = targets.steam,
    capabilities = { reactors = #config.reactors, turbines = #config.turbines }
  }
  network:send(constants.channels.STATUS, protocol.status(network.id, network.role, payload))
end

local function hello()
  local caps = { reactors = #config.reactors, turbines = #config.turbines }
  network:broadcast(protocol.hello(network.id, network.role, caps))
end

local function set_reactors_active(active)
  for _, reactor in pairs(peripherals.reactors) do
    pcall(reactor.setActive, active)
  end
end

local function scram()
  set_reactors_active(false)
end

local function adjust_reactors()
  for _, reactor in pairs(peripherals.reactors) do
    local temp = reactor.getCasingTemperature and reactor.getCasingTemperature() or 0
    if temp > config.safety.max_temperature then
      scram()
      current_state:transition(constants.node_states.EMERGENCY)
      return
    end
    if reactor.setControlRodsLevels then
      local level = 100 - math.min(100, targets.power / (#config.reactors * 10))
      reactor.setControlRodsLevels(level)
    end
  end
end

local function adjust_turbines()
  for _, turbine in pairs(peripherals.turbines) do
    if turbine.setInductorEngaged then turbine.setInductorEngaged(true) end
    if turbine.setActive then turbine.setActive(true) end
    local rpm = turbine.getRotorSpeed and turbine.getRotorSpeed() or 0
    if turbine.setFlowRate then
      local request = safety.safe_steam_request(targets.steam, 4000)
      turbine.setFlowRate(request)
    end
    if rpm > targets.rpm * 1.1 then
      turbine.setFlowRate(targets.steam * 0.8)
    end
  end
end

local function monitor_master()
  if os.epoch("utc") - master_seen > config.heartbeat_interval * 5000 then
    if current_state.state() ~= constants.node_states.AUTONOM then
      utils.log("RT", "Master timeout, entering AUTONOM")
      current_state:transition(constants.node_states.AUTONOM)
    end
  end
end

local states = {
  [constants.node_states.OFF] = {
    on_enter = function()
      scram()
      targets.power, targets.steam, targets.rpm = 0, 0, 0
    end,
    on_tick = function()
      monitor_master()
    end
  },
  [constants.node_states.STARTUP] = {
    on_enter = function()
      set_reactors_active(true)
      targets.steam = 500
      targets.rpm = 900
    end,
    on_tick = function()
      adjust_turbines()
      adjust_reactors()
      monitor_master()
      current_state:transition(constants.node_states.RUNNING)
    end
  },
  [constants.node_states.RUNNING] = {
    on_tick = function()
      adjust_turbines()
      adjust_reactors()
      monitor_master()
    end
  },
  [constants.node_states.LIMITED] = {
    on_tick = function()
      targets.power = targets.power * 0.5
      adjust_reactors()
      adjust_turbines()
      monitor_master()
    end
  },
  [constants.node_states.AUTONOM] = {
    on_enter = function()
      targets.power = math.min(targets.power, 5000)
    end,
    on_tick = function()
      adjust_reactors()
      adjust_turbines()
      if os.epoch("utc") - master_seen < config.heartbeat_interval * 2000 then
        current_state:transition(constants.node_states.RUNNING)
      end
    end
  },
  [constants.node_states.MANUAL] = {
    on_tick = function()
      monitor_master()
    end
  },
  [constants.node_states.EMERGENCY] = {
    on_enter = function()
      scram()
      targets.power, targets.steam, targets.rpm = 0, 0, 0
      add_alarm(network.id, "EMERGENCY", "SCRAM triggered")
    end,
    on_tick = function()
      monitor_master()
    end
  }
}

local function handle_command(message)
  if not protocol.is_for_node(message, network.id) then return end
  local command = message.payload.command
  if not command then return end
  master_seen = os.epoch("utc")
  if command.target == constants.command_targets.POWER_TARGET then
    targets.power = command.value
  elseif command.target == constants.command_targets.STEAM_TARGET then
    targets.steam = command.value
  elseif command.target == constants.command_targets.TURBINE_RPM then
    targets.rpm = command.value
  elseif command.target == constants.command_targets.MODE then
    if states[command.value] then
      current_state:transition(command.value)
    end
  elseif command.target == constants.command_targets.SCRAM then
    current_state:transition(constants.node_states.EMERGENCY)
  end
  network:send(constants.channels.CONTROL, protocol.ack(network.id, network.role, command.command_id, "ack"))
end

local function send_heartbeat()
  network:send(constants.channels.STATUS, protocol.heartbeat(network.id, network.role, current_state.state()))
  broadcast_status(constants.status_levels.OK)
  last_heartbeat = os.epoch("utc")
end

local function tick_loop()
  while true do
    current_state:tick()
    local message = network:receive(0.2)
    if message then
      if message.type == constants.message_types.COMMAND then
        handle_command(message)
      elseif message.type == constants.message_types.HELLO then
        master_seen = os.epoch("utc")
      end
    end
    if os.epoch("utc") - last_heartbeat > config.heartbeat_interval * 1000 then
      send_heartbeat()
    end
  end
end

local function init()
  cache()
  network = network_lib.init(config)
  current_state = machine.new(states, constants.node_states.OFF)
  hello()
  send_heartbeat()
  utils.log("RT", "Node ready: " .. network.id)
end

init()
tick_loop()
