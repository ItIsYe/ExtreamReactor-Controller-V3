package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local constants = require("shared.constants")
local protocol = require("core.protocol")
local utils = require("core.utils")
local safety = require("core.safety")
local network_lib = require("core.network")
local machine = require("core.state_machine")

local function log(level, message)
  local stamp = textutils.formatTime(os.epoch("utc") / 1000, true)
  print(string.format("[%s] RT | %s | %s", stamp, level, message))
end

local function loadConfig()
  local path = "/xreactor/nodes/rt/config.lua"
  if not fs.exists(path) then
    error("RT config.lua not found: " .. path)
  end
  local f = fs.open(path, "r")
  local content = f.readAll()
  f.close()

  local fn, err = load(content, "rt_config", "t", {})
  if not fn then error(err) end
  return fn()
end

local config = loadConfig()
config.safety = config.safety or {}
config.safety.max_temperature = config.safety.max_temperature or 2000
config.safety.max_rpm = config.safety.max_rpm or 1800
config.safety.min_water = config.safety.min_water or 0.2
config.heartbeat_interval = config.heartbeat_interval or 2
config.autonom = config.autonom or {}
config.autonom.control_rod_level = config.autonom.control_rod_level or 85
config.autonom.control_rod_step = config.autonom.control_rod_step or 1
config.autonom.target_rpm = config.autonom.target_rpm or 900
config.autonom.max_rpm = config.autonom.max_rpm or 1000
config.autonom.rpm_step = config.autonom.rpm_step or 25
config.autonom.target_steam = config.autonom.target_steam or 1000
config.autonom.max_steam = config.autonom.max_steam or 1500
config.autonom.steam_step = config.autonom.steam_step or 50
local hb = config.heartbeat_interval

local network
local peripherals = {}
local targets = { power = 0, steam = 0, rpm = 0 }
local modules = {}
local active_startup = nil
local startup_queue = {}
local master_seen = os.epoch("utc")
local last_heartbeat = 0
local mode = constants.roles.MASTER
local status_snapshot = nil
local last_snapshot = 0

local STATE = {
  INIT = "INIT",
  AUTONOM = "AUTONOM",
  MASTER = "MASTER",
  SAFE = "SAFE"
}

local current_state = STATE.INIT
local node_state_machine

local ramp_profiles = {
  FAST = 4000,
  NORMAL = 8000,
  SLOW = 12000
}

local function ramp_towards(current, target, step)
  if current == nil then return target end
  local delta = target - current
  if math.abs(delta) <= step then
    return target
  end
  if delta > 0 then
    return current + step
  end
  return current - step
end

local function update_autonom_control_rods(module)
  if not module.peripheral or not module.peripheral.setControlRodsLevels then
    return
  end
  if not module.autonom_control_rod then
    if module.peripheral.getControlRodLevel then
      local ok, level = pcall(module.peripheral.getControlRodLevel)
      if ok then
        module.autonom_control_rod = level
      end
    end
  end
  local target = safety.clamp(config.autonom.control_rod_level, 0, 100)
  local current = module.autonom_control_rod or target
  local next_level = ramp_towards(current, target, config.autonom.control_rod_step)
  module.autonom_control_rod = next_level
  module.peripheral.setControlRodsLevels(next_level)
end

local allowed_transitions = {
  [STATE.INIT] = { [STATE.AUTONOM] = true, [STATE.MASTER] = true, [STATE.SAFE] = true },
  [STATE.MASTER] = { [STATE.AUTONOM] = true, [STATE.SAFE] = true },
  [STATE.AUTONOM] = { [STATE.MASTER] = true, [STATE.SAFE] = true },
  [STATE.SAFE] = {}
}

local function setState(new_state)
  if current_state == new_state then
    return false
  end
  if not allowed_transitions[current_state] or not allowed_transitions[current_state][new_state] then
    return false
  end
  local previous_state = current_state
  current_state = new_state
  if new_state == STATE.AUTONOM then
    log("INFO", "Entering AUTONOM mode")
  elseif new_state == STATE.MASTER then
    if previous_state == STATE.AUTONOM then
      log("INFO", "Master reconnected")
    else
      log("INFO", "Entering MASTER mode")
    end
  elseif new_state == STATE.SAFE then
    log("INFO", "Entering SAFE mode")
  else
    log("INFO", "Entering INIT mode")
  end
  return true
end

local function cache()
  peripherals.reactors = utils.cache_peripherals(config.reactors)
  peripherals.turbines = utils.cache_peripherals(config.turbines)
  if config.steam_buffer and peripheral.isPresent(config.steam_buffer) then
    peripherals.steam_buffer = peripheral.wrap(config.steam_buffer)
  end
end

local function build_modules()
  modules = {}
  for i, name in ipairs(config.turbines) do
    local id = "turbine:" .. i
    modules[id] = { id = id, type = "turbine", state = "OFF", progress = 0, limits = {}, name = name, stable_since = nil }
  end
  for i, name in ipairs(config.reactors) do
    local id = "reactor:" .. i
    modules[id] = {
      id = id,
      type = "reactor",
      state = "OFF",
      progress = 0,
      limits = {},
      name = name,
      stable_since = nil,
      autonom_control_rod = nil
    }
  end
end

local function refresh_module_peripherals()
  for _, module in pairs(modules) do
    if module.type == "turbine" then
      module.peripheral = peripherals.turbines[module.name]
    else
      module.peripheral = peripherals.reactors[module.name]
    end
  end
end

local function get_steam_amount()
  local buffer = peripherals.steam_buffer
  if not buffer then return nil end
  if buffer.getAmount then
    local ok, amount = pcall(buffer.getAmount)
    if ok then return amount end
  end
  if buffer.getFluidAmount then
    local ok, amount = pcall(buffer.getFluidAmount)
    if ok then return amount end
  end
  if buffer.getStored then
    local ok, amount = pcall(buffer.getStored)
    if ok then return amount end
  end
  return nil
end

local function ramp_duration(profile)
  return ramp_profiles[profile] or ramp_profiles.NORMAL
end

local function add_alarm(sender, severity, message)
  network:send(constants.channels.CONTROL, protocol.alert(sender, config.role, severity, message))
end

local function module_payload()
  local snapshot = {}
  for id, module in pairs(modules) do
    snapshot[id] = {
      state = module.state,
      progress = module.progress,
      limits = module.limits
    }
  end
  return snapshot
end

local function broadcast_status(status_level)
  local payload = {
    status = status_level,
    state = node_state_machine.state(),
    mode = current_state,
    output = targets.power,
    turbine_rpm = targets.rpm,
    steam = targets.steam,
    capabilities = { reactors = #config.reactors, turbines = #config.turbines },
    modules = module_payload(),
    snapshot = status_snapshot
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

local function update_module_limits(module)
  local limits = {}
  if module.type == "turbine" then
    local water = get_steam_amount()
    if water and water < config.safety.reserve_steam then
      table.insert(limits, "WATER")
    end
    local rpm = module.peripheral and module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or 0
    if targets.rpm > 0 and rpm > 0 and rpm < targets.rpm * 0.7 then
      table.insert(limits, "RPM")
    end
  elseif module.type == "reactor" then
    local water = get_steam_amount()
    if water and water < config.safety.reserve_steam then
      table.insert(limits, "WATER")
    end
    local temp = module.peripheral and module.peripheral.getCasingTemperature and module.peripheral.getCasingTemperature() or 0
    if temp > config.safety.max_temperature then
      table.insert(limits, "TEMP")
    end
  end
  module.limits = limits
  return limits
end

local function adjust_reactors()
  local active = 0
  for _, module in pairs(modules) do
    if module.type == "reactor" and module.peripheral and module.state ~= "OFF" and module.state ~= "ERROR" then
      active = active + 1
    end
  end
  for _, module in pairs(modules) do
    if module.type == "reactor" and module.peripheral then
      if module.state == "OFF" or module.state == "ERROR" then
        if module.peripheral.setActive then module.peripheral.setActive(false) end
      else
        local temp = module.peripheral.getCasingTemperature and module.peripheral.getCasingTemperature() or 0
        if temp > config.safety.max_temperature then
          module.state = "ERROR"
          module.progress = 0
          module.limits = { "TEMP" }
          if current_state ~= STATE.SAFE then
            log("ERROR", "Safety trigger: reactor temperature limit exceeded")
            setState(STATE.SAFE)
          end
          if node_state_machine.state() ~= constants.node_states.EMERGENCY then
            node_state_machine:transition(constants.node_states.EMERGENCY)
          end
          return
        end
        if module.peripheral.setControlRodsLevels then
          if current_state == STATE.AUTONOM then
            update_autonom_control_rods(module)
          else
            local level = 100 - math.min(100, targets.power / (math.max(1, active) * 10))
            module.autonom_control_rod = nil
            module.peripheral.setControlRodsLevels(level)
          end
        end
      end
    end
  end
end

local function adjust_turbines()
  for _, module in pairs(modules) do
    if module.type == "turbine" and module.peripheral then
      if module.state == "OFF" or module.state == "ERROR" then
        if module.peripheral.setActive then module.peripheral.setActive(false) end
      else
        if module.peripheral.setInductorEngaged then module.peripheral.setInductorEngaged(true) end
        if module.peripheral.setActive then module.peripheral.setActive(true) end
        local rpm = module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or 0
        if module.peripheral.setFlowRate then
          local request = safety.safe_steam_request(targets.steam, 4000)
          module.peripheral.setFlowRate(request)
        end
        if rpm > targets.rpm * 1.1 and module.peripheral.setFlowRate then
          module.peripheral.setFlowRate(targets.steam * 0.8)
        end
      end
    end
  end
end

local function check_interlocks(module)
  local limits = update_module_limits(module)
  if module.type == "turbine" then
    for _, limit in ipairs(limits) do
      if limit == "WATER" then
        return false, limits
      end
    end
  elseif module.type == "reactor" then
    for _, limit in ipairs(limits) do
      if limit == "TEMP" or limit == "WATER" then
        return false, limits
      end
    end
  end
  if not module.peripheral then
    return false, limits
  end
  return true, limits
end

local function mark_stable(module, now)
  module.state = "STABLE"
  module.progress = 1
  module.stable_since = now
end

local function start_module(module_id, module_type, ramp_profile)
  local module = modules[module_id]
  if not module or module.type ~= module_type then
    return nil, "Unknown module"
  end
  if active_startup and active_startup ~= module_id then
    return nil, "Startup busy"
  end
  if module.state == "STARTING" then
    return module, "Starting"
  end
  if module.state == "STABLE" or module.state == "RUNNING" then
    return module, "Already running"
  end
  module.state = "STARTING"
  module.progress = 0
  module.limits = {}
  module.start_time = os.epoch("utc")
  module.ramp_profile = ramp_profile or "NORMAL"
  module.stable_since = nil
  active_startup = module_id
  return module, "Starting"
end

local function process_startup()
  if not active_startup then return end
  local module = modules[active_startup]
  if not module then
    active_startup = nil
    return
  end
  local ok, limits = check_interlocks(module)
  if not ok then
    module.state = "ERROR"
    module.progress = 0
    module.limits = limits
    active_startup = nil
    add_alarm(network.id, "EMERGENCY", "Startup blocked for " .. module.id)
    return
  end
  local now = os.epoch("utc")
  local duration = ramp_duration(module.ramp_profile)
  local progress = safety.clamp((now - module.start_time) / duration, 0, 1)
  module.progress = progress
  if module.type == "turbine" then
    if module.peripheral.setActive then module.peripheral.setActive(true) end
    if module.peripheral.setInductorEngaged then module.peripheral.setInductorEngaged(true) end
    if module.peripheral.setFlowRate then
      local request = safety.safe_steam_request(4000 * progress, 4000)
      module.peripheral.setFlowRate(request)
    end
    local rpm = module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or 0
    if progress >= 1 and rpm >= 1600 then
      mark_stable(module, now)
      active_startup = nil
    end
  elseif module.type == "reactor" then
    if module.peripheral.setActive then module.peripheral.setActive(true) end
    if module.peripheral.setControlRodsLevels then
      local level = 100 - math.floor(progress * 100)
      module.peripheral.setControlRodsLevels(level)
    end
    local temp = module.peripheral.getCasingTemperature and module.peripheral.getCasingTemperature() or 0
    if progress >= 1 and temp > 0 and temp < config.safety.max_temperature then
      mark_stable(module, now)
      active_startup = nil
    end
  end
end

local function update_module_states()
  local now = os.epoch("utc")
  for _, module in pairs(modules) do
    local limits = update_module_limits(module)
    if module.type == "reactor" and module.state ~= "OFF" then
      for _, limit in ipairs(limits) do
        if limit == "TEMP" then
          module.state = "ERROR"
          module.progress = 0
          if current_state ~= STATE.SAFE then
            log("ERROR", "Safety trigger: reactor temperature limit exceeded")
            setState(STATE.SAFE)
          end
          if node_state_machine.state() ~= constants.node_states.EMERGENCY then
            node_state_machine:transition(constants.node_states.EMERGENCY)
          end
        end
      end
    end
    if module.state == "STABLE" and module.stable_since and (now - module.stable_since > 3000) then
      if node_state_machine.state() == constants.node_states.RUNNING then
        module.state = "RUNNING"
      end
    end
    if module.state == "RUNNING" and #module.limits > 0 then
      module.state = "LIMITED"
    elseif module.state == "LIMITED" and #module.limits == 0 then
      module.state = "RUNNING"
    end
  end
end

local function monitor_master()
  if os.epoch("utc") - master_seen > hb * 5000 then
    if setState(STATE.AUTONOM) then
      log("WARN", "Master timeout detected, switching to AUTONOM")
      node_state_machine:transition(constants.node_states.AUTONOM)
    end
  end
end

local function clamp_autonom_targets()
  targets.power = 0
  local rpm_target = safety.clamp(config.autonom.target_rpm, 0, config.autonom.max_rpm)
  local steam_target = safety.clamp(config.autonom.target_steam, 0, config.autonom.max_steam)
  targets.rpm = ramp_towards(targets.rpm, rpm_target, config.autonom.rpm_step)
  targets.steam = ramp_towards(targets.steam, steam_target, config.autonom.steam_step)
end

local function note_master_seen()
  master_seen = os.epoch("utc")
  if setState(STATE.MASTER) then
    if node_state_machine.state() == constants.node_states.AUTONOM then
      node_state_machine:transition(constants.node_states.RUNNING)
    end
  end
end

local function update_status_snapshot()
  local now = os.epoch("utc")
  local interval = (config.status_interval or 5) * 1000
  if now - last_snapshot < interval then
    return status_snapshot
  end
  last_snapshot = now

  local temp_sum, temp_count, temp_max = 0, 0, 0
  for _, name in ipairs(config.reactors) do
    local reactor = peripherals.reactors[name]
    if reactor and reactor.getCasingTemperature then
      local ok, temp = pcall(reactor.getCasingTemperature)
      if ok and type(temp) == "number" then
        temp_sum = temp_sum + temp
        temp_count = temp_count + 1
        if temp > temp_max then
          temp_max = temp
        end
      end
    end
  end

  local rpm_sum, rpm_count = 0, 0
  for _, name in ipairs(config.turbines) do
    local turbine = peripherals.turbines[name]
    if turbine and turbine.getRotorSpeed then
      local ok, rpm = pcall(turbine.getRotorSpeed)
      if ok and type(rpm) == "number" then
        rpm_sum = rpm_sum + rpm
        rpm_count = rpm_count + 1
      end
    end
  end

  local avg_temp = temp_count > 0 and (temp_sum / temp_count) or 0
  local avg_rpm = rpm_count > 0 and (rpm_sum / rpm_count) or 0
  local master_connected = (os.epoch("utc") - master_seen) <= hb * 5000

  status_snapshot = {
    node_id = network and network.id or config.role,
    state = current_state,
    master_connected = master_connected,
    reactor_count = #config.reactors,
    turbine_count = #config.turbines,
    avg_temp = avg_temp,
    max_temp = temp_max,
    avg_rpm = avg_rpm,
    timestamp = now
  }

  if config.status_log then
    log("INFO", "Status snapshot updated")
  end

  return status_snapshot
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
      targets.steam = 500
      targets.rpm = 900
      startup_queue = {}
      for i = 1, #config.turbines do
        table.insert(startup_queue, "turbine:" .. i)
      end
      for i = 1, #config.reactors do
        table.insert(startup_queue, "reactor:" .. i)
      end
    end,
    on_tick = function()
      if not active_startup and #startup_queue > 0 then
        local next_id = table.remove(startup_queue, 1)
        local module = modules[next_id]
        if module then
          start_module(module.id, module.type, "NORMAL")
        end
      end
      adjust_turbines()
      adjust_reactors()
      monitor_master()
      if not active_startup and #startup_queue == 0 then
        node_state_machine:transition(constants.node_states.RUNNING)
      end
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
      active_startup = nil
      startup_queue = {}
      clamp_autonom_targets()
    end,
    on_tick = function()
      clamp_autonom_targets()
      adjust_reactors()
      adjust_turbines()
      if current_state == STATE.MASTER then
        node_state_machine:transition(constants.node_states.RUNNING)
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
  if current_state == STATE.SAFE then
    network:send(constants.channels.CONTROL, protocol.ack(network.id, network.role, command.command_id, "safe: ignoring commands"))
    return
  end
  local was_autonom = current_state == STATE.AUTONOM
  note_master_seen()
  if was_autonom then
    if command.target == constants.command_targets.POWER_TARGET
      or command.target == constants.command_targets.STEAM_TARGET
      or command.target == constants.command_targets.TURBINE_RPM
      or command.target == constants.command_targets.REQUEST_STARTUP_MODULE
      or command.target == constants.command_targets.MODE then
      network:send(constants.channels.CONTROL, protocol.ack(network.id, network.role, command.command_id, "autonom: holding safe targets"))
      return
    end
  end
  if command.target == constants.command_targets.POWER_TARGET then
    targets.power = command.value
  elseif command.target == constants.command_targets.STEAM_TARGET then
    targets.steam = command.value
  elseif command.target == constants.command_targets.TURBINE_RPM then
    targets.rpm = command.value
  elseif command.target == constants.command_targets.MODE then
    if states[command.value] then
      node_state_machine:transition(command.value)
    end
  elseif command.target == constants.command_targets.REQUEST_STARTUP_MODULE then
    local value = command.value or {}
    local module, detail = start_module(value.module_id, value.module_type, value.ramp_profile)
    if not module then
      add_alarm(network.id, "WARNING", "Startup rejected: " .. (detail or "unknown"))
      network:send(constants.channels.CONTROL, protocol.ack(network.id, network.role, command.command_id, detail or "ack"))
      return
    end
    network:send(constants.channels.CONTROL, protocol.ack(network.id, network.role, command.command_id, detail or "ack", module.id))
    return
  elseif command.target == constants.command_targets.SCRAM then
    setState(STATE.SAFE)
    if node_state_machine.state() ~= constants.node_states.EMERGENCY then
      node_state_machine:transition(constants.node_states.EMERGENCY)
    end
  end
  network:send(constants.channels.CONTROL, protocol.ack(network.id, network.role, command.command_id, "ack"))
end

local function send_heartbeat()
  update_status_snapshot()
  network:send(constants.channels.STATUS, protocol.heartbeat(network.id, network.role, node_state_machine.state()))
  broadcast_status(constants.status_levels.OK)
  last_heartbeat = os.epoch("utc")
end

local function tick_loop()
  while true do
    refresh_module_peripherals()
    process_startup()
    update_module_states()
    if current_state == STATE.SAFE and node_state_machine.state() ~= constants.node_states.EMERGENCY then
      node_state_machine:transition(constants.node_states.EMERGENCY)
    end
    node_state_machine:tick()
    local message = network:receive(0.2)
    if message then
      if message.type == constants.message_types.COMMAND then
        handle_command(message)
      elseif message.type == constants.message_types.HELLO then
        note_master_seen()
      end
    end
    if os.epoch("utc") - last_heartbeat > hb * 1000 then
      send_heartbeat()
    end
    update_status_snapshot()
  end
end

local function init()
  cache()
  build_modules()
  refresh_module_peripherals()
  network = network_lib.init(config)
  node_state_machine = machine.new(states, constants.node_states.OFF)
  hello()
  send_heartbeat()
  log("INFO", "Node ready: " .. network.id)
end

init()
tick_loop()
