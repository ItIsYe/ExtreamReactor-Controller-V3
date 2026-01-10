package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local constants = require("shared.constants")
local colors = require("shared.colors")
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
local TARGET_RPM = 900
local RPM_TOL = 20
local MIN_FLOW = 200
local MAX_FLOW = 1900
local FLOW_STEP = 50
local COIL_ENGAGE_RPM = 850
local COIL_DISENG_RPM = 750
local START_FLOW = MIN_FLOW
local ROD_TICK = 2.0
local ROD_MIN = 0
local ROD_MAX = 98
local INITIAL_ROD_LEVEL = ROD_MAX
local MIN_APPLY_INTERVAL = 1.5
local REACTOR_STEP = 5
local STEAM_LOW = 0.20
local STEAM_HIGH = 0.80
local last_applied_rods = nil
local last_rod_apply_ts = 0
local last_rod_change_ts = 0
local last_rod_direction = nil
config.safety = config.safety or {}
config.safety.max_temperature = config.safety.max_temperature or 2000
config.safety.max_rpm = config.safety.max_rpm or 1800
config.safety.min_water = config.safety.min_water or 0.2
config.heartbeat_interval = config.heartbeat_interval or 2
config.autonom = config.autonom or {}
config.autonom.control_rod_level = config.autonom.control_rod_level or 70
config.autonom.target_rpm = TARGET_RPM
config.autonom.max_rpm = math.max(config.autonom.max_rpm or TARGET_RPM, TARGET_RPM)
config.autonom.min_flow = math.max(config.autonom.min_flow or MIN_FLOW, MIN_FLOW)
config.autonom.max_flow = math.min(config.autonom.max_flow or MAX_FLOW, MAX_FLOW)
config.autonom.flow_step = config.autonom.flow_step or FLOW_STEP
config.autonom.ramp_step = config.autonom.ramp_step or config.autonom.flow_step
config.autonom.min_rods = config.autonom.min_rods or ROD_MIN
config.autonom.max_rods = config.autonom.max_rods or ROD_MAX
config.autonom.reactor_adjust_interval = config.autonom.reactor_adjust_interval or 2
config.monitor_interval = config.monitor_interval or 2
config.monitor_scale = config.monitor_scale or 0.5
local hb = config.heartbeat_interval

local network
local peripherals = {}
local steam_tank = nil
local targets = { power = 0, steam = 0, rpm = 0 }
local modules = {}
local active_startup = nil
local startup_queue = {}
local master_seen = os.epoch("utc")
local last_heartbeat = 0
local last_reactor_tick = 0
local last_reactor_debug_log = 0
local mode = constants.roles.MASTER
local status_snapshot = nil
local last_snapshot = 0
local monitor = nil
local last_monitor_update = 0
local last_actuator_update = 0
local warned = {}
local autonom_state = { reactors = {}, turbines = {} }
local autonom_control_logged = false
local capability_cache = { reactors = {}, turbines = {} }
local turbine_ctrl = {}
local reactor_ctrl = {}

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

local TURBINE_MODE = {
  RAMP = "RAMP",
  REGULATE = "REGULATE"
}

local function clamp_turbine_flow(rate)
  if type(rate) ~= "number" then
    rate = config.autonom.min_flow
  end
  return safety.clamp(rate, MIN_FLOW, MAX_FLOW)
end

local function clamp_rods(level, allow_overmax)
  if type(level) ~= "number" then
    level = ROD_MAX
  end
  local max_limit = allow_overmax and 100 or ROD_MAX
  return safety.clamp(level, ROD_MIN, max_limit)
end

local function reactor_low_water(reactor)
  if not reactor or not reactor.getCoolantAmount or not reactor.getCoolantAmountMax then
    return false
  end
  local ok_amount, amount = pcall(reactor.getCoolantAmount)
  local ok_max, max = pcall(reactor.getCoolantAmountMax)
  if not ok_amount or not ok_max or type(amount) ~= "number" or type(max) ~= "number" or max <= 0 then
    return false
  end
  return (amount / max) <= config.safety.min_water
end

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

local function has_method(methods, method)
  for _, name in ipairs(methods or {}) do
    if name == method then
      return true
    end
  end
  return false
end

local function build_capabilities(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    methods = {}
  end
  return {
    setActive = has_method(methods, "setActive"),
    setFluidFlowRate = has_method(methods, "setFluidFlowRate"),
    setFluidFlowRateMax = has_method(methods, "setFluidFlowRateMax"),
    getControlRods = has_method(methods, "getControlRods"),
    setInductorEngaged = has_method(methods, "setInductorEngaged"),
    setAllControlRodLevels = has_method(methods, "setAllControlRodLevels")
  }
end

local function ensure_turbine_ctrl(name)
  local ctrl = turbine_ctrl[name]
  if not ctrl then
    ctrl = { flow = clamp_turbine_flow(START_FLOW), mode = TURBINE_MODE.RAMP }
    turbine_ctrl[name] = ctrl
  end
  return ctrl
end

local function init_turbine_ctrl()
  turbine_ctrl = {}
  autonom_state.turbines = turbine_ctrl
  local turbines = config.turbines or {}
  log("INFO", "Detected " .. tostring(#turbines) .. " turbines")
  if #turbines < 1 then
    log("ERROR", "No turbines detected")
    return
  end
  for _, name in ipairs(turbines) do
    turbine_ctrl[name] = {
      flow = clamp_turbine_flow(START_FLOW),
      mode = TURBINE_MODE.RAMP,
      logged = false
    }
    log("INFO", "Controlling turbine: " .. name)
  end
end

local function get_device_caps(kind, name)
  capability_cache[kind] = capability_cache[kind] or {}
  if not capability_cache[kind][name] or peripheral.isPresent(name) then
    capability_cache[kind][name] = build_capabilities(name)
  end
  return capability_cache[kind][name]
end

local function setReactorActive(reactor, caps, active)
  if caps.setActive then
    reactor.setActive(active)
    return true
  end
  return false
end

local function setTurbineFlow(turbine, caps, rate)
  local clamped = clamp_turbine_flow(rate)
  if caps.setFluidFlowRate then
    turbine.setFluidFlowRate(clamped)
    return true
  elseif caps.setFluidFlowRateMax then
    turbine.setFluidFlowRateMax(clamped)
    return true
  end
  return false
end

local function setInductor(turbine, caps, engaged)
  if caps.setInductorEngaged then
    turbine.setInductorEngaged(engaged)
    return true
  end
  return false
end

local function setTurbineActive(turbine, caps, active)
  if caps.setActive then
    turbine.setActive(active)
    return true
  end
  return false
end

local function ensure_reactor_ctrl(name)
  local ctrl = reactor_ctrl[name]
  if not ctrl then
    ctrl = { last_steam_pct = nil, last_applied = nil, last_adjust = 0, initialized = false }
    reactor_ctrl[name] = ctrl
  end
  return ctrl
end

local function init_reactor_ctrl()
  reactor_ctrl = {}
  for _, name in ipairs(config.reactors or {}) do
    reactor_ctrl[name] = {
      last_steam_pct = nil,
      last_applied = nil,
      last_adjust = 0,
      initialized = false
    }
  end
end

function applyReactorRods(target, allow_overmax)
  local now = os.clock()
  if now - last_rod_apply_ts < MIN_APPLY_INTERVAL then
    return
  end
  if type(target) ~= "number" then
    return
  end
  local clamped = clamp_rods(target, allow_overmax)
  if last_applied_rods == clamped then
    autonom_state.pending_rod_direction = nil
    return
  end
  for name, ctrl in pairs(reactor_ctrl) do
    local reactor = peripheral.wrap(name)
    local caps = get_device_caps("reactors", name)
    if reactor and caps.setAllControlRodLevels then
      local ok, result = pcall(reactor.setAllControlRodLevels, clamped)
      if ok and result ~= false then
        ctrl.last_applied = clamped
      else
        warn_once("reactor_rods:" .. name, "Reactor control rod write failed for " .. name)
      end
    elseif reactor and reactor.getControlRods then
      local ok_rods, rods = pcall(reactor.getControlRods)
      if ok_rods and type(rods) == "table" then
        for _, rod in pairs(rods) do
          if rod and rod.setLevel then
            pcall(rod.setLevel, clamped)
          end
        end
        ctrl.last_applied = clamped
      else
        warn_once("reactor_rods:" .. name, "Reactor control rod read failed for " .. name)
      end
    else
      warn_once("reactor_rods:" .. name, "Reactor control rods unsupported for " .. name)
    end
  end
  local previous_applied = last_applied_rods
  last_applied_rods = clamped
  last_rod_apply_ts = now
  local applied_direction = autonom_state.pending_rod_direction
  if applied_direction == nil and type(previous_applied) == "number" then
    if clamped < previous_applied then
      applied_direction = "DOWN"
    elseif clamped > previous_applied then
      applied_direction = "UP"
    end
  end
  if applied_direction ~= nil then
    last_rod_change_ts = now
    last_rod_direction = applied_direction
  end
  autonom_state.pending_rod_direction = nil
  log("INFO", "Applied rods " .. tostring(clamped) .. "%")
end

local function apply_initial_reactor_rods()
  for name, ctrl in pairs(reactor_ctrl) do
    ctrl.last_applied = nil
    log("INFO", "Reactor " .. name .. " initial rods set to " .. tostring(INITIAL_ROD_LEVEL) .. "%")
  end
  applyReactorRods(INITIAL_ROD_LEVEL, false)
end

local function read_current_rods()
  for _, name in ipairs(config.reactors or {}) do
    local reactor = peripheral.wrap(name)
    if reactor and reactor.getControlRodLevel then
      local ok_rods, current_rods = pcall(reactor.getControlRodLevel, 0)
      if ok_rods and type(current_rods) == "number" then
        return current_rods
      end
    end
  end
  return nil
end

local function log_reactor_control_state()
  local now = os.clock()
  if now - last_reactor_debug_log < 5 then
    return
  end
  last_reactor_debug_log = now
  local sample_rods = read_current_rods() or ROD_MAX
  local tick_age = now - last_reactor_tick
  log("DEBUG", "ReactorCtrl state=" .. tostring(current_state) .. " rods=" .. tostring(sample_rods) .. " ticks=" .. string.format("%.1f", tick_age) .. "s")
end

local function log_reactor_control_tick()
  local sample_rods = read_current_rods() or ROD_MAX
  local sample_steam = nil
  for _, ctrl in pairs(reactor_ctrl) do
    sample_steam = ctrl.last_steam_pct
    break
  end
  local age = os.clock() - last_rod_change_ts
  log(
    "DEBUG",
    "ReactorCtrl rods="
      .. tostring(sample_rods)
      .. " steam="
      .. tostring(sample_steam)
      .. " dir="
      .. tostring(last_rod_direction)
      .. " age="
      .. string.format("%.1f", age)
  )
  if sample_steam ~= nil then
    log("INFO", "ReactorCtrl steam=" .. tostring(math.floor(sample_steam * 100)) .. "% rods=" .. tostring(sample_rods))
  else
    log("INFO", "ReactorCtrl steam=nil rods=" .. tostring(sample_rods))
  end
end

local function read_steam_pct()
  if not steam_tank or not steam_tank.getStored or not steam_tank.getCapacity then
    return 0
  end
  local ok_fluids, fluids = pcall(steam_tank.getStored)
  local ok_capacity, capacity = pcall(steam_tank.getCapacity)
  if not ok_fluids or not ok_capacity or type(capacity) ~= "number" or capacity <= 0 or type(fluids) ~= "table" then
    return 0
  end
  local steam = 0
  for _, f in pairs(fluids) do
    if f and (f.name == "mekanism:steam" or f.name == "steam") then
      steam = f.amount or 0
      break
    end
  end
  local steam_pct = steam / capacity
  if steam == 0 and steam_pct == 0 then
    steam_pct = 0
  end
  return steam_pct
end

local function update_reactor_setpoints()
  if current_state == STATE.SAFE then
    return
  end
  local now = os.epoch("utc")
  local steam_pct = read_steam_pct()
  for name, ctrl in pairs(reactor_ctrl) do
    local last_adjust = ctrl.last_adjust or 0
    ctrl.initialized = true
    local reactor = peripheral.wrap(name)
    if reactor and reactor.getControlRodLevel and reactor.setAllControlRodLevels then
      local ok_rods, current_rods = pcall(reactor.getControlRodLevel, 0)
      if ok_rods and type(current_rods) == "number" then
        ctrl.last_steam_pct = steam_pct
        if now - last_adjust >= (ROD_TICK * 1000) then
          local target_rods = current_rods
          if steam_pct < STEAM_LOW then
            target_rods = current_rods - REACTOR_STEP
            autonom_state.pending_rod_direction = "DOWN"
          elseif steam_pct > STEAM_HIGH then
            target_rods = current_rods + REACTOR_STEP
            autonom_state.pending_rod_direction = "UP"
          end
          target_rods = clamp_rods(target_rods, false)
          if target_rods ~= current_rods then
            local ok_set, set_result = pcall(reactor.setAllControlRodLevels, target_rods)
            if ok_set and set_result ~= false then
              autonom_state.reactor_target = target_rods
              log("INFO", "Reactor rods " .. tostring(current_rods) .. " -> " .. tostring(target_rods) .. " (steam " .. tostring(math.floor(steam_pct * 100)) .. "%)")
            else
              warn_once("reactor_rods:" .. name, "Reactor control rod write failed for " .. name)
            end
          end
          ctrl.last_adjust = now
        end
      else
        warn_once("reactor_rods:" .. name, "Reactor control rod read failed for " .. name)
      end
    else
      warn_once("reactor_rods:" .. name, "Reactor control rods unsupported for " .. name)
    end
  end
end

local function updateReactorControl()
  last_reactor_tick = os.clock()
  log("DEBUG", "Reactor control tick")
  if current_state == STATE.SAFE then
    applyReactorRods(ROD_MAX, true)
    return
  end
  log_reactor_control_state()
  update_reactor_setpoints()
  log_reactor_control_tick()
end

function warn_once(key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  log("WARN", message)
end

local function warn_unsupported(name)
  warn_once("device_unsupported:" .. name, "Device unsupported by API: " .. name)
end

local function update_inductor_for_rpm(name, turbine, caps, rpm)
  local ctrl = ensure_turbine_ctrl(name)
  local engaged = ctrl.inductor_engaged or false
  if rpm and rpm >= COIL_ENGAGE_RPM and not engaged then
    engaged = true
  elseif (not rpm or rpm <= COIL_DISENG_RPM) and engaged then
    engaged = false
  end
  if engaged == ctrl.inductor_engaged then
    return true, true
  end
  ctrl.inductor_engaged = engaged
  return pcall(setInductor, turbine, caps, engaged)
end

local function update_turbine_flow_state(rpm, target_rpm, ctrl)
  local mode = ctrl.mode or TURBINE_MODE.RAMP
  local ramp_step = FLOW_STEP
  local flow_step = FLOW_STEP
  if mode == TURBINE_MODE.RAMP then
    if not rpm or rpm < TARGET_RPM then
      ctrl.flow = ctrl.flow + ramp_step
    else
      ctrl.mode = TURBINE_MODE.REGULATE
    end
  else
    if rpm and rpm < TARGET_RPM - RPM_TOL then
      ctrl.flow = ctrl.flow + flow_step
    elseif rpm and rpm > TARGET_RPM + RPM_TOL then
      ctrl.flow = ctrl.flow - flow_step
    end
  end
  ctrl.flow = clamp_turbine_flow(ctrl.flow)
  return ctrl.flow, ctrl.mode
end

local function apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
  local ctrl = ensure_turbine_ctrl(name)
  if type(rpm) == "number" then
    ctrl.rpm = rpm
  end
  local flow, mode = update_turbine_flow_state(rpm, target_rpm, ctrl)
  local ok, result = pcall(setTurbineFlow, turbine, caps, flow)
  log("DEBUG", "Turbine " .. name .. " rpm=" .. tostring(rpm) .. " flow=" .. tostring(flow) .. " mode=" .. tostring(mode) .. " coil=" .. tostring(ctrl.inductor_engaged))
  if not ctrl.logged then
    log("INFO", "Turbine " .. name .. " active, initial flow " .. tostring(ctrl.flow))
    ctrl.logged = true
  end
  return ok, result
end

local set_reactors_active
local set_turbines_active
local apply_safe_controls

local function updateActuators()
  if current_state ~= STATE.AUTONOM then
    return
  end
  update_reactor_setpoints()
  for _, name in ipairs(config.reactors) do
    local reactor
    if peripheral.isPresent(name) then
      local wrapped, err = utils.safe_wrap(name)
      if wrapped then
        reactor = wrapped
      else
        warn_once("reactor_wrap:" .. name, "Reactor wrap failed for " .. name .. ": " .. tostring(err))
      end
    else
      warn_once("reactor_missing:" .. name, "Reactor missing: " .. name)
    end
    if reactor then
      local caps = get_device_caps("reactors", name)
      if not (caps.getControlRods or caps.setAllControlRodLevels) then
        warn_unsupported(name)
        goto continue_reactor
      end
      local ok_active, active_result = pcall(setReactorActive, reactor, caps, true)
      if not ok_active then
        warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_reactor
      end
      if not active_result then
        warn_unsupported(name)
        goto continue_reactor
      end
      ensure_reactor_ctrl(name)
      ::continue_reactor::
    end
  end

  local target_rpm = TARGET_RPM
  for name, ctrl in pairs(turbine_ctrl) do
    local turbine
    if peripheral.isPresent(name) then
      local wrapped, err = utils.safe_wrap(name)
      if wrapped then
        turbine = wrapped
      else
        warn_once("turbine_wrap:" .. name, "Turbine wrap failed for " .. name .. ": " .. tostring(err))
      end
    else
      warn_once("turbine_missing:" .. name, "Turbine missing: " .. name)
    end
    if turbine then
      local caps = get_device_caps("turbines", name)
      if not caps.setInductorEngaged then
        warn_unsupported(name)
        goto continue_turbine
      end
      if not (caps.setFluidFlowRate or caps.setFluidFlowRateMax) then
        warn_unsupported(name)
        goto continue_turbine
      end
      local ok_active, active_result = pcall(setTurbineActive, turbine, caps, true)
      if not ok_active then
        warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_turbine
      end
      if not active_result then
        warn_unsupported(name)
        goto continue_turbine
      end
      local rpm = nil
      if turbine.getRotorSpeed then
        local ok, value = pcall(turbine.getRotorSpeed)
        if ok and type(value) == "number" then
          rpm = value
        end
      end
      local ok_inductor, inductor_result = update_inductor_for_rpm(name, turbine, caps, rpm)
      if not ok_inductor then
        warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
        goto continue_turbine
      end
      if not inductor_result then
        warn_unsupported(name)
        goto continue_turbine
      end
      local ok, result = apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
      if not ok then
        warn_once("turbine_flow:" .. name, "Turbine flow update failed for " .. name .. ": " .. tostring(result))
        goto continue_turbine
      end
      if not result then
        warn_unsupported(name)
      end
      ::continue_turbine::
    end
  end
end

local function updateControl()
  if current_state ~= STATE.AUTONOM then
    return
  end

  update_reactor_setpoints()
  for _, name in ipairs(config.reactors or {}) do
    local ok, reactor = pcall(peripheral.wrap, name)
    if ok and reactor then
      local caps = get_device_caps("reactors", name)
      if not (caps.getControlRods or caps.setAllControlRodLevels) then
        warn_unsupported(name)
        goto continue_control_reactor
      end
      local ok_active, active_result = pcall(setReactorActive, reactor, caps, true)
      if not ok_active then
        warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_control_reactor
      end
      if not active_result then
        warn_unsupported(name)
        goto continue_control_reactor
      end
      ensure_reactor_ctrl(name)
      if not autonom_control_logged then
        autonom_control_logged = true
        log("INFO", "AUTONOM actuator control active")
      end
      ::continue_control_reactor::
    end
  end

  local target_rpm = TARGET_RPM
  for name, ctrl in pairs(turbine_ctrl) do
    local ok, turbine = pcall(peripheral.wrap, name)
    if ok and turbine then
      local caps = get_device_caps("turbines", name)
      if not caps.setInductorEngaged then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      if not (caps.setFluidFlowRate or caps.setFluidFlowRateMax) then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      local ok_active, active_result = pcall(setTurbineActive, turbine, caps, true)
      if not ok_active then
        warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_control_turbine
      end
      if not active_result then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      local rpm = nil
      if turbine.getRotorSpeed then
        local ok, value = pcall(turbine.getRotorSpeed)
        if ok and type(value) == "number" then
          rpm = value
        end
      end
      local ok_inductor, inductor_result = update_inductor_for_rpm(name, turbine, caps, rpm)
      if not ok_inductor then
        warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
        goto continue_control_turbine
      end
      if not inductor_result then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      local set_ok, result = apply_turbine_flow(name, turbine, caps, rpm, target_rpm)
      if not set_ok then
        warn_once("turbine_flow:" .. name, "Turbine flow update failed for " .. name .. ": " .. tostring(result))
        goto continue_control_turbine
      end
      if not result then
        warn_unsupported(name)
        goto continue_control_turbine
      end
      if not autonom_control_logged then
        autonom_control_logged = true
        log("INFO", "AUTONOM actuator control active")
      end
      ::continue_control_turbine::
    end
  end
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
    apply_safe_controls()
    set_reactors_active(false)
    set_turbines_active(false)
  else
    log("INFO", "Entering INIT mode")
  end
  return true
end

local function cache()
  peripherals.reactors = utils.cache_peripherals(config.reactors)
  peripherals.turbines = utils.cache_peripherals(config.turbines)
  for _, name in ipairs(config.reactors) do
    capability_cache.reactors[name] = build_capabilities(name)
  end
  for _, name in ipairs(config.turbines) do
    capability_cache.turbines[name] = build_capabilities(name)
  end
end

local function detect_steam_tank()
  local ok_find, found = pcall(peripheral.find, "mekanism:ultimate_fluid_tank")
  if ok_find and found then
    return found
  end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "fluid_storage") then
      local ok_wrap, wrapped = pcall(peripheral.wrap, name)
      if ok_wrap and wrapped then
        return wrapped
      end
    end
  end
  return nil
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
      module.caps = module.peripheral and get_device_caps("turbines", module.name) or nil
    else
      module.peripheral = peripherals.reactors[module.name]
      module.caps = module.peripheral and get_device_caps("reactors", module.name) or nil
    end
  end
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

set_reactors_active = function(active)
  for name, reactor in pairs(peripherals.reactors) do
    local caps = get_device_caps("reactors", name)
    local ok, result = pcall(setReactorActive, reactor, caps, active)
    if not ok then
      warn_once("reactor_active:" .. name, "Reactor activate failed for " .. name .. ": " .. tostring(result))
    elseif not result then
      warn_unsupported(name)
    end
  end
end

set_turbines_active = function(active)
  for name, turbine in pairs(peripherals.turbines) do
    local caps = get_device_caps("turbines", name)
    local ok, result = pcall(setTurbineActive, turbine, caps, active)
    if not ok then
      warn_once("turbine_active:" .. name, "Turbine activate failed for " .. name .. ": " .. tostring(result))
    elseif not result then
      warn_unsupported(name)
    end
  end
end

apply_safe_controls = function()
  for name, reactor in pairs(peripherals.reactors) do
    local caps = get_device_caps("reactors", name)
    if caps.getControlRods or caps.setAllControlRodLevels then
      local ctrl = ensure_reactor_ctrl(name)
      ctrl.last_applied = nil
    else
      warn_unsupported(name)
    end
  end
  applyReactorRods(100, true)

  for name, turbine in pairs(peripherals.turbines) do
    local caps = get_device_caps("turbines", name)
    local rpm = turbine.getRotorSpeed and turbine.getRotorSpeed() or nil
    if caps.setInductorEngaged then
      local ok, result = update_inductor_for_rpm(name, turbine, caps, rpm)
      if not ok then
        warn_once("turbine_inductor:" .. name, "Turbine inductor update failed for " .. name .. ": " .. tostring(result))
      elseif not result then
        warn_unsupported(name)
      end
    end
    if caps.setFluidFlowRate or caps.setFluidFlowRateMax then
      local ctrl = ensure_turbine_ctrl(name)
      ctrl.mode = TURBINE_MODE.RAMP
      ctrl.flow = clamp_turbine_flow(ctrl.flow)
      local ok, result = pcall(setTurbineFlow, turbine, caps, ctrl.flow)
      if not ok then
        warn_once("turbine_flow:" .. name, "Turbine flow update failed for " .. name .. ": " .. tostring(result))
      elseif not result then
        warn_unsupported(name)
      end
    else
      warn_unsupported(name)
    end
  end
end

local function scram()
  apply_safe_controls()
  if current_state == STATE.SAFE then
    set_reactors_active(false)
    set_turbines_active(false)
  end
end

local function update_module_limits(module)
  local limits = {}
  if module.type == "turbine" then
    local rpm = module.peripheral and module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or 0
    if TARGET_RPM > 0 and rpm > 0 and rpm < TARGET_RPM * 0.7 then
      table.insert(limits, "RPM")
    end
  elseif module.type == "reactor" then
    local temp = module.peripheral and module.peripheral.getCasingTemperature and module.peripheral.getCasingTemperature() or 0
    if temp > config.safety.max_temperature then
      table.insert(limits, "TEMP")
    end
    if reactor_low_water(module.peripheral) then
      table.insert(limits, "WATER")
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
  update_reactor_setpoints()
  for _, module in pairs(modules) do
    if module.type == "reactor" and module.peripheral then
      if module.state == "OFF" or module.state == "ERROR" then
        ensure_reactor_ctrl(module.name)
      else
        if (current_state == STATE.AUTONOM or current_state == STATE.MASTER) and module.caps then
          local ok_active, active_result = pcall(setReactorActive, module.peripheral, module.caps, true)
          if ok_active and not active_result then
            warn_unsupported(module.name)
          end
        end
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
        if reactor_low_water(module.peripheral) then
          module.state = "ERROR"
          module.progress = 0
          module.limits = { "WATER" }
          if current_state ~= STATE.SAFE then
            log("ERROR", "Safety trigger: reactor coolant level too low")
            setState(STATE.SAFE)
          end
          if node_state_machine.state() ~= constants.node_states.EMERGENCY then
            node_state_machine:transition(constants.node_states.EMERGENCY)
          end
          return
        end
        if not module.caps or not (module.caps.getControlRods or module.caps.setAllControlRodLevels) then
          warn_unsupported(module.name)
          goto continue_adjust_reactor
        elseif module.caps and (module.caps.getControlRods or module.caps.setAllControlRodLevels) then
          ensure_reactor_ctrl(module.name)
        end
      end
    end
    ::continue_adjust_reactor::
  end
end

local function adjust_turbines()
  local target_rpm = TARGET_RPM
  for _, module in pairs(modules) do
    if module.type == "turbine" and module.peripheral then
      if module.state == "OFF" or module.state == "ERROR" then
        local rpm = module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or nil
        if module.caps and module.caps.setInductorEngaged then
          local ok_inductor, inductor_result = update_inductor_for_rpm(module.name, module.peripheral, module.caps, rpm)
          if not ok_inductor then
            warn_once("turbine_inductor:" .. module.name, "Turbine inductor update failed for " .. module.name .. ": " .. tostring(inductor_result))
          elseif not inductor_result then
            warn_unsupported(module.name)
          end
        end
        if module.caps and (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
          local ctrl = ensure_turbine_ctrl(module.name)
          ctrl.mode = TURBINE_MODE.RAMP
          ctrl.flow = clamp_turbine_flow(ctrl.flow)
          local ok_flow, flow_result = pcall(setTurbineFlow, module.peripheral, module.caps, ctrl.flow)
          if not ok_flow then
            warn_once("turbine_flow:" .. module.name, "Turbine flow update failed for " .. module.name .. ": " .. tostring(flow_result))
          elseif not flow_result then
            warn_unsupported(module.name)
          end
        end
        local ctrl = ensure_turbine_ctrl(module.name)
        ctrl.mode = TURBINE_MODE.RAMP
      elseif module.state == "STARTING" then
        goto continue_adjust_turbine
      else
        if not module.caps or not module.caps.setInductorEngaged then
          warn_unsupported(module.name)
          goto continue_adjust_turbine
        end
        if not module.caps or not (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
          warn_unsupported(module.name)
          goto continue_adjust_turbine
        end
        if (current_state == STATE.AUTONOM or current_state == STATE.MASTER) and module.caps then
          local ok_active, active_result = pcall(setTurbineActive, module.peripheral, module.caps, true)
          if ok_active and not active_result then
            warn_unsupported(module.name)
          end
        end
        local rpm = module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or nil
        local ok_inductor, inductor_result = update_inductor_for_rpm(module.name, module.peripheral, module.caps, rpm)
        if not ok_inductor then
          warn_once("turbine_inductor:" .. module.name, "Turbine inductor update failed for " .. module.name .. ": " .. tostring(inductor_result))
          goto continue_adjust_turbine
        end
        if not inductor_result then
          warn_unsupported(module.name)
          goto continue_adjust_turbine
        end
        local ok_flow, flow_result = apply_turbine_flow(module.name, module.peripheral, module.caps, rpm, target_rpm)
        if not ok_flow then
          warn_once("turbine_flow:" .. module.name, "Turbine flow update failed for " .. module.name .. ": " .. tostring(flow_result))
          goto continue_adjust_turbine
        end
        if not flow_result then
          warn_unsupported(module.name)
          goto continue_adjust_turbine
        end
      end
    end
    ::continue_adjust_turbine::
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
  if module.type == "turbine" then
    local ctrl = ensure_turbine_ctrl(module.name)
    ctrl.mode = TURBINE_MODE.RAMP
  end
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
    if module.caps then
      local ok_active, active_result = pcall(setTurbineActive, module.peripheral, module.caps, true)
      if ok_active and not active_result then
        warn_unsupported(module.name)
      end
    end
    if not module.caps or not module.caps.setInductorEngaged then
      warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    if not module.caps or not (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
      warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    local rpm = module.peripheral.getRotorSpeed and module.peripheral.getRotorSpeed() or nil
    local ok_inductor, inductor_result = update_inductor_for_rpm(module.name, module.peripheral, module.caps, rpm)
    if not ok_inductor then
      warn_once("turbine_inductor:" .. module.name, "Turbine inductor update failed for " .. module.name .. ": " .. tostring(inductor_result))
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    if not inductor_result then
      warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    if module.caps and (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
      local target_rpm = TARGET_RPM
      local ctrl = ensure_turbine_ctrl(module.name)
      local flow, mode = update_turbine_flow_state(rpm, target_rpm, ctrl)
      local ok_flow, flow_result = pcall(setTurbineFlow, module.peripheral, module.caps, ctrl.flow)
      if not ok_flow then
        warn_once("turbine_flow:" .. module.name, "Turbine flow update failed for " .. module.name .. ": " .. tostring(flow_result))
        module.state = "ERROR"
        module.progress = 0
        module.limits = { "CONTROL" }
        active_startup = nil
        return
      end
      if not flow_result then
        warn_unsupported(module.name)
        module.state = "ERROR"
        module.progress = 0
        module.limits = { "CONTROL" }
        active_startup = nil
        return
      end
      if not ctrl.logged then
        log("INFO", "Turbine " .. module.name .. " active, initial flow " .. tostring(ctrl.flow))
        ctrl.logged = true
      end
      log("DEBUG", "Turbine " .. module.name .. " rpm=" .. tostring(rpm) .. " flow=" .. tostring(flow) .. " mode=" .. tostring(mode))
    end
    local target_rpm = TARGET_RPM
    rpm = rpm or 0
    if target_rpm > 0 then
      module.progress = safety.clamp(rpm / target_rpm, 0, 1)
    else
      module.progress = 0
    end
    if rpm >= target_rpm and target_rpm > 0 then
      mark_stable(module, now)
      active_startup = nil
    end
  elseif module.type == "reactor" then
    if module.caps then
      local ok_active, active_result = pcall(setReactorActive, module.peripheral, module.caps, true)
      if ok_active and not active_result then
        warn_unsupported(module.name)
      end
    end
    if not module.caps or not (module.caps.getControlRods or module.caps.setAllControlRodLevels) then
      warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      active_startup = nil
      return
    end
    if module.caps and (module.caps.getControlRods or module.caps.setAllControlRodLevels) then
      local level = 100 - math.floor(progress * 100)
      local ctrl = ensure_reactor_ctrl(module.name)
      ctrl.last_applied = nil
      applyReactorRods(level, false)
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
        if limit == "TEMP" or limit == "WATER" then
          module.state = "ERROR"
          module.progress = 0
          if current_state ~= STATE.SAFE then
            if limit == "WATER" then
              log("ERROR", "Safety trigger: reactor coolant level too low")
            else
              log("ERROR", "Safety trigger: reactor temperature limit exceeded")
            end
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
  targets.rpm = ramp_towards(targets.rpm, TARGET_RPM, config.autonom.flow_step)
  targets.steam = 0
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

local function init_monitor()
  local ok, found = pcall(peripheral.find, "monitor")
  if ok then
    monitor = found
  end
  if monitor then
    pcall(monitor.setTextScale, config.monitor_scale)
    pcall(monitor.setBackgroundColor, colors.black)
    pcall(monitor.setTextColor, colors.white)
    pcall(monitor.clear)
  end
end

local function update_monitor()
  if not monitor then return end
  local now = os.epoch("utc")
  if now - last_monitor_update < (config.monitor_interval * 1000) then
    return
  end
  last_monitor_update = now
  local snapshot = update_status_snapshot()
  local avg_temp = snapshot and snapshot.avg_temp or 0
  local lines = {
    "RT Node: " .. (network and network.id or config.node_id or "RT"),
    "State: " .. tostring(current_state),
    "Reactors: " .. tostring(#config.reactors),
    "Turbines: " .. tostring(#config.turbines),
    string.format("Avg Temp: %.1f", avg_temp),
    "Target RPM: " .. tostring(TARGET_RPM)
  }
  pcall(monitor.setBackgroundColor, colors.black)
  pcall(monitor.setTextColor, colors.white)
  pcall(monitor.clear)
  for i, line in ipairs(lines) do
    pcall(monitor.setCursorPos, 1, i)
    pcall(monitor.write, line)
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
      targets.steam = 0
      targets.rpm = TARGET_RPM
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
    targets.rpm = TARGET_RPM
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

local function mainEventLoop()
  while true do
    refresh_module_peripherals()
    process_startup()
    update_module_states()
    updateReactorControl()
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
    update_monitor()
    update_status_snapshot()
  end
end

local function init()
  steam_tank = detect_steam_tank()
  if steam_tank then
    log("INFO", "Steam tank detected")
  else
    log("WARN", "Steam tank not detected")
  end
  cache()
  init_turbine_ctrl()
  init_reactor_ctrl()
  build_modules()
  refresh_module_peripherals()
  set_reactors_active(true)
  set_turbines_active(true)
  apply_initial_reactor_rods()
  network = network_lib.init(config)
  node_state_machine = machine.new(states, constants.node_states.OFF)
  init_monitor()
  hello()
  send_heartbeat()
  log("INFO", "Node ready: " .. network.id)
end

init()
parallel.waitForAny(
  function()
    while true do
      updateControl()
      sleep(1)
    end
  end,
  mainEventLoop
)
