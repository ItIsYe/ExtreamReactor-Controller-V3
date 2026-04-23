local M = {}

local function has_off_modules(modules, kind)
  for _, module in pairs(modules or {}) do
    if module.type == kind and module.state == "OFF" then
      return true
    end
  end
  return false
end

function M.build(ctx)
  local function assert_fn(name)
    if type(ctx[name]) ~= "function" then
      error("state handler context missing function: " .. tostring(name), 2)
    end
    return ctx[name]
  end

  local adjust_reactors = assert_fn("adjust_reactors")
  local adjust_turbines = assert_fn("adjust_turbines")

  local constants = ctx.constants
  local STATE = ctx.STATE

  local function off_on_enter()
    ctx.reset_startup_watchdog()
    ctx.scram()
    ctx.targets.power, ctx.targets.steam, ctx.targets.rpm = 0, 0, 0
  end

  local function off_on_tick()
    ctx.monitor_master()
  end

  local function startup_on_enter()
    ctx.set_startup_started_ms(os.epoch("utc"))
    ctx.set_startup_watchdog_tripped(false)
    ctx.targets.steam = 0
    ctx.targets.rpm = ctx.get_target_rpm()
    local queue = {}
    for _, entry in ipairs(ctx.devices.turbines or {}) do
      local module = ctx.modules[entry.id]
      if module and module.state == "OFF" and ctx.targets.enable_turbines ~= false then
        table.insert(queue, entry.id)
      end
    end
    for _, entry in ipairs(ctx.devices.reactors or {}) do
      local module = ctx.modules[entry.id]
      if module and module.state == "OFF" and ctx.targets.enable_reactors ~= false then
        table.insert(queue, entry.id)
      end
    end
    ctx.set_startup_queue(queue)
  end

  local function startup_on_tick()
    local startup_started_ms = ctx.get_startup_started_ms()
    if startup_started_ms and not ctx.get_startup_watchdog_tripped() then
      local now = os.epoch("utc")
      if now - startup_started_ms >= (ctx.config.startup_watchdog_s or 60) * 1000 then
        ctx.handle_startup_timeout()
      end
    end
    if not ctx.get_active_startup() and #ctx.get_startup_queue() > 0 then
      local next_id = table.remove(ctx.get_startup_queue(), 1)
      local module = ctx.modules[next_id]
      if module then
        ctx.start_module(module.id, module.type, "NORMAL")
      end
    end
    adjust_turbines()
    adjust_reactors()
    ctx.monitor_master()
    if not ctx.get_active_startup() and #ctx.get_startup_queue() == 0 then
      ctx.get_node_state_machine():transition(constants.node_states.RUNNING)
    end
  end

  local function running_on_enter()
    ctx.reset_startup_watchdog()
  end

  local function running_on_tick()
    adjust_turbines()
    adjust_reactors()
    ctx.monitor_master()
  end

  local function limited_on_enter()
    ctx.reset_startup_watchdog()
  end

  local function limited_on_tick()
    ctx.targets.power = ctx.targets.power * 0.5
    adjust_reactors()
    adjust_turbines()
    ctx.monitor_master()
  end

  local function autonom_on_enter()
    ctx.reset_startup_watchdog()
    ctx.set_active_startup(nil)
    ctx.set_startup_queue({})
    ctx.clamp_autonom_targets()
  end

  local function autonom_on_tick()
    ctx.clamp_autonom_targets()
    adjust_reactors()
    adjust_turbines()
    if ctx.get_current_state() == STATE.MASTER then
      ctx.get_node_state_machine():transition(constants.node_states.RUNNING)
    end
  end

  local function manual_on_enter()
    ctx.reset_startup_watchdog()
  end

  local function manual_on_tick()
    ctx.monitor_master()
  end

  local function emergency_on_enter()
    ctx.reset_startup_watchdog()
    ctx.scram()
    ctx.targets.power, ctx.targets.steam, ctx.targets.rpm = 0, 0, 0
    ctx.add_alarm(ctx.comms.network.id, "EMERGENCY", "SCRAM triggered")
  end

  local function emergency_on_tick()
    ctx.monitor_master()
  end

  return {
    [constants.node_states.OFF] = {
      on_enter = off_on_enter,
      on_tick = off_on_tick
    },
    [constants.node_states.STARTUP] = {
      on_enter = startup_on_enter,
      on_tick = startup_on_tick
    },
    [constants.node_states.RUNNING] = {
      on_enter = running_on_enter,
      on_tick = running_on_tick
    },
    [constants.node_states.LIMITED] = {
      on_enter = limited_on_enter,
      on_tick = limited_on_tick
    },
    [constants.node_states.AUTONOM] = {
      on_enter = autonom_on_enter,
      on_tick = autonom_on_tick
    },
    [constants.node_states.MANUAL] = {
      on_enter = manual_on_enter,
      on_tick = manual_on_tick
    },
    [constants.node_states.EMERGENCY] = {
      on_enter = emergency_on_enter,
      on_tick = emergency_on_tick
    }
  }
end

function M.request_startup_if_needed(ctx, reason)
  if ctx.get_current_state() ~= ctx.STATE.MASTER then
    return false
  end
  local machine_state = ctx.get_node_state_machine() and ctx.get_node_state_machine().state and ctx.get_node_state_machine():state() or nil
  if machine_state ~= ctx.constants.node_states.RUNNING and machine_state ~= ctx.constants.node_states.OFF then
    return false
  end
  local needs_turbine = ctx.targets.enable_turbines ~= false and has_off_modules(ctx.modules, "turbine")
  local needs_reactor = ctx.targets.enable_reactors ~= false and has_off_modules(ctx.modules, "reactor")
  if not needs_turbine and not needs_reactor then
    return false
  end
  if ctx.get_active_startup() then
    return false
  end
  ctx.log("INFO", ("Startup requested reason=%s turbines_off=%s reactors_off=%s"):format(
    tostring(reason or "unknown"),
    tostring(needs_turbine),
    tostring(needs_reactor)
  ))
  ctx.get_node_state_machine():transition(ctx.constants.node_states.STARTUP)
  return true
end

function M.set_state(ctx, new_state, transition_reason)
  local current_state = ctx.get_current_state()
  if current_state == new_state then
    return false
  end
  if not ctx.allowed_transitions[current_state] or not ctx.allowed_transitions[current_state][new_state] then
    return false
  end
  ctx.set_current_state(new_state)
  if new_state == ctx.STATE.AUTONOM then
    ctx.log("INFO", "Entering AUTONOM mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
  elseif new_state == ctx.STATE.MASTER then
    if current_state == ctx.STATE.AUTONOM then
      ctx.log("INFO", "Master reconnected reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    else
      ctx.log("INFO", "Entering MASTER mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    end
  elseif new_state == ctx.STATE.SAFE then
    ctx.log("INFO", "Entering SAFE mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    ctx.apply_safe_controls()
    ctx.set_reactors_active(false, "SAFE_MODE")
    ctx.set_turbines_active(false, "SAFE_MODE")
  else
    ctx.log("INFO", "Entering INIT mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
  end
  return true
end

function M.apply_mode(ctx, mode)
  if mode == ctx.STATE.AUTONOM then
    if M.set_state(ctx, ctx.STATE.AUTONOM, "MODE_APPLY") then
      ctx.get_node_state_machine():transition(ctx.constants.node_states.AUTONOM)
    end
  elseif mode == ctx.STATE.MASTER then
    if M.set_state(ctx, ctx.STATE.MASTER, "MODE_APPLY") then
      local current = ctx.get_node_state_machine():state()
      if current == ctx.constants.node_states.OFF or current == ctx.constants.node_states.AUTONOM then
        ctx.get_node_state_machine():transition(ctx.constants.node_states.STARTUP)
      end
    end
  elseif mode == ctx.STATE.SAFE then
    M.set_state(ctx, ctx.STATE.SAFE, "MODE_APPLY")
    if ctx.get_node_state_machine():state() ~= ctx.constants.node_states.EMERGENCY then
      ctx.get_node_state_machine():transition(ctx.constants.node_states.EMERGENCY)
    end
  end
end

function M.monitor_master(ctx)
  local connected = ctx.is_master_connected()
  if not connected then
    if M.set_state(ctx, ctx.STATE.AUTONOM, "MASTER_TIMEOUT_AUTONOM_FALLBACK") then
      ctx.log("WARN", "Master timeout detected, switching to AUTONOM")
      ctx.get_node_state_machine():transition(ctx.constants.node_states.AUTONOM)
    end
  end
end

function M.clamp_autonom_targets(ctx)
  ctx.targets.power = 0
  ctx.targets.rpm = ctx.ramp_towards(ctx.targets.rpm, ctx.TARGET_RPM, ctx.config.autonom.flow_step)
  ctx.targets.steam = 0
end

return M
