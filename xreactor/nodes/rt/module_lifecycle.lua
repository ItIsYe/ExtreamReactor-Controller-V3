local safety = require("core.safety")
local turbine_regulator = require("core.turbine_regulator")

local M = {}

local function safe_wrapped_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(function(...)
    return obj[method](...)
  end, ...)
end

local function has_reactor_rod_write_path(caps)
  return caps and (caps.setAllControlRodLevels or caps.setControlRodLevel or caps.getControlRods)
end

function M.update_module_limits(ctx, module)
  local limits = {}
  if module.type == "turbine" then
    local _, rpm_value = safe_wrapped_call(module.peripheral, "getRotorSpeed")
    local rpm = type(rpm_value) == "number" and rpm_value or 0
    local target_rpm = ctx.get_target_rpm()
    if target_rpm > 0 and rpm > 0 and rpm < target_rpm * 0.7 then
      table.insert(limits, "RPM")
    end
  elseif module.type == "reactor" then
    module.safety_temp_state = module.safety_temp_state or {}
    local _, fuel_temp_value = safe_wrapped_call(module.peripheral, "getFuelTemperature")
    local _, temp_value = safe_wrapped_call(module.peripheral, "getCasingTemperature")
    local temp_eval = safety.evaluate_temperature_limit({
      fuel_temperature = fuel_temp_value,
      casing_temperature = temp_value,
      max_temperature = ctx.config.safety.max_temperature,
      hysteresis = ctx.config.safety.temperature_hysteresis,
      trip_samples = ctx.config.safety.temperature_trip_samples,
      state = module.safety_temp_state
    })
    module.temperature_safety_diag = temp_eval
    if module.last_temperature_condition ~= temp_eval.condition then
      ctx.log("DEBUG", ("Temperature safety diag module=%s condition=%s value=%s limit=%s source=%s fuel_temp=%s casing_temp=%s hysteresis=%s over_limit_ticks=%s trip_samples=%s"):format(
        tostring(module.id),
        tostring(temp_eval.condition),
        tostring(temp_eval.temperature),
        tostring(temp_eval.max_temperature),
        tostring(temp_eval.source),
        tostring(temp_eval.fuel_temperature),
        tostring(temp_eval.casing_temperature),
        tostring(temp_eval.hysteresis),
        tostring(temp_eval.over_limit_ticks),
        tostring(temp_eval.trip_samples)
      ))
      module.last_temperature_condition = temp_eval.condition
    end
    if temp_eval.triggered then
      table.insert(limits, "TEMP")
    end
    module.coolant_safety_state = module.coolant_safety_state or {}
    local coolant_eval = ctx.evaluate_reactor_coolant(module.peripheral, module.coolant_safety_state)
    module.coolant_safety_diag = coolant_eval
    if coolant_eval and module.last_coolant_condition ~= coolant_eval.condition then
      ctx.log("DEBUG", ("Coolant safety diag module=%s condition=%s amount=%s max=%s ratio=%s ratio_raw=%s threshold=%s recover_threshold=%s hysteresis=%s source=%s source_method=%s measurement_state=%s measurement_valid=%s stale_fallback=%s low_ticks=%s trip_samples=%s invalid_ticks=%s invalid_grace=%s zero_glitch_pending=%s zero_glitch_ticks=%s"):format(
        tostring(module.id),
        tostring(coolant_eval.condition),
        tostring(coolant_eval.coolant_amount),
        tostring(coolant_eval.coolant_amount_max),
        tostring(coolant_eval.coolant_ratio),
        tostring(coolant_eval.coolant_ratio_raw),
        tostring(coolant_eval.min_water),
        tostring(coolant_eval.recover_threshold),
        tostring(coolant_eval.hysteresis),
        tostring(coolant_eval.source),
        tostring(coolant_eval.source_method),
        tostring(coolant_eval.measurement_state),
        tostring(coolant_eval.measurement_valid),
        tostring(coolant_eval.stale_fallback_used),
        tostring(coolant_eval.low_ticks),
        tostring(coolant_eval.trip_samples),
        tostring(coolant_eval.invalid_ticks),
        tostring(coolant_eval.invalid_grace_samples),
        tostring(coolant_eval.zero_glitch_pending),
        tostring(coolant_eval.zero_glitch_ticks)
      ))
      module.last_coolant_condition = coolant_eval.condition
    end
    if coolant_eval and coolant_eval.triggered then
      table.insert(limits, "WATER")
    end
  end
  module.limits = limits
  return limits
end

function M.check_interlocks(ctx, module)
  local limits = M.update_module_limits(ctx, module)
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

function M.mark_stable(ctx, module, now)
  local previous = module.state
  module.state = "STABLE"
  module.progress = 1
  module.stable_since = now
  if previous ~= module.state then
    ctx.log("INFO", ("Module state %s %s -> %s reason=STARTUP_STABLE"):format(tostring(module.id), tostring(previous), tostring(module.state)))
  end
end

function M.start_module(ctx, module_id, module_type, ramp_profile)
  local module = ctx.modules[module_id]
  if not module or module.type ~= module_type then
    return nil, "Unknown module"
  end
  local active_startup = ctx.get_active_startup()
  if active_startup and active_startup ~= module_id then
    return nil, "Startup busy"
  end
  if module.state == "STARTING" then
    return module, "Starting"
  end
  if module.state == "STABLE" or module.state == "RUNNING" then
    return module, "Already running"
  end
  local previous = module.state
  module.state = "STARTING"
  module.progress = 0
  module.limits = {}
  module.start_time = os.epoch("utc")
  module.ramp_profile = ramp_profile or "NORMAL"
  module.stable_since = nil
  ctx.set_active_startup(module_id)
  ctx.log("INFO", ("Module state %s %s -> %s reason=START_REQUEST profile=%s"):format(
    tostring(module.id),
    tostring(previous),
    tostring(module.state),
    tostring(module.ramp_profile)
  ))
  if module.type == "turbine" then
    local ctrl = ctx.get_turbine_ctrl(module.name)
    ctrl.mode = ctx.TURBINE_MODE.RAMP
  end
  return module, "Starting"
end

function M.process_startup(ctx)
  local active_startup = ctx.get_active_startup()
  if not active_startup then return end
  local module = ctx.modules[active_startup]
  if not module then
    ctx.set_active_startup(nil)
    return
  end
  local ok, limits = M.check_interlocks(ctx, module)
  if not ok then
    module.state = "ERROR"
    module.progress = 0
    module.limits = limits
    ctx.set_active_startup(nil)
    ctx.add_alarm(ctx.comms.network.id, "EMERGENCY", "Startup blocked for " .. module.id)
    return
  end
  local now = os.epoch("utc")
  local duration = ctx.ramp_duration(module.ramp_profile)
  local progress = safety.clamp((now - module.start_time) / duration, 0, 1)
  module.progress = progress
  if module.type == "turbine" then
    if module.caps then
      local ok_active, active_result = pcall(ctx.setTurbineActive, module.peripheral, module.caps, true)
      if ok_active and not active_result then
        ctx.warn_unsupported(module.name)
      end
    end
    if not module.caps or not module.caps.setInductorEngaged then
      ctx.warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      ctx.set_active_startup(nil)
      return
    end
    if not module.caps or not (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
      ctx.warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      ctx.set_active_startup(nil)
      return
    end
    local _, rpm_value = safe_wrapped_call(module.peripheral, "getRotorSpeed")
    local rpm = type(rpm_value) == "number" and rpm_value or nil
    local ok_inductor, inductor_result = ctx.update_inductor_for_rpm(module.name, module.peripheral, module.caps, rpm)
    if not ok_inductor then
      ctx.warn_once("turbine_inductor:" .. module.name, "Turbine inductor update failed for " .. module.name .. ": " .. tostring(inductor_result))
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      ctx.set_active_startup(nil)
      return
    end
    if not inductor_result then
      ctx.warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      ctx.set_active_startup(nil)
      return
    end
    if module.caps and (module.caps.setFluidFlowRate or module.caps.setFluidFlowRateMax) then
      local target_rpm = ctx.get_target_rpm()
      local ctrl = ctx.get_turbine_ctrl(module.name)
      local flow, mode = ctx.update_turbine_flow_state(rpm, target_rpm, ctrl)
      local ok_flow, flow_result = pcall(ctx.setTurbineFlow, module.peripheral, module.caps, ctrl.flow)
      if not ok_flow then
        ctx.warn_once("turbine_flow:" .. module.name, "Turbine flow update failed for " .. module.name .. ": " .. tostring(flow_result))
        module.state = "ERROR"
        module.progress = 0
        module.limits = { "CONTROL" }
        ctx.set_active_startup(nil)
        return
      end
      if not flow_result then
        ctx.warn_unsupported(module.name)
        module.state = "ERROR"
        module.progress = 0
        module.limits = { "CONTROL" }
        ctx.set_active_startup(nil)
        return
      end
      if not ctrl.logged then
        ctx.log("INFO", "Turbine " .. module.name .. " active, initial flow " .. tostring(ctrl.flow))
        ctrl.logged = true
      end
      ctx.log("DEBUG", "Turbine " .. module.name .. " rpm=" .. tostring(rpm) .. " flow=" .. tostring(flow) .. " mode=" .. tostring(mode))
    end
    local target_rpm = ctx.get_target_rpm()
    rpm = rpm or 0
    if target_rpm > 0 then
      module.progress = safety.clamp(rpm / target_rpm, 0, 1)
    else
      module.progress = 0
    end
    if turbine_regulator.startup_reached_target(rpm, target_rpm, ctx.RPM_TOL) then
      M.mark_stable(ctx, module, now)
      ctx.set_active_startup(nil)
    end
  elseif module.type == "reactor" then
    if module.caps then
      local ok_active, active_result = pcall(ctx.setReactorActive, module.peripheral, module.caps, true)
      if ok_active and not active_result then
        ctx.warn_unsupported(module.name)
      end
    end
    if not has_reactor_rod_write_path(module.caps) then
      ctx.warn_unsupported(module.name)
      module.state = "ERROR"
      module.progress = 0
      module.limits = { "CONTROL" }
      ctx.set_active_startup(nil)
      return
    end
    if has_reactor_rod_write_path(module.caps) then
      local level = 100 - math.floor(progress * 100)
      local ctrl = ctx.ensure_reactor_ctrl(module.name)
      ctrl.last_applied = nil
      ctx.applyReactorRods(level, false)
    end
    local _, temp_value = safe_wrapped_call(module.peripheral, "getCasingTemperature")
    local temp = type(temp_value) == "number" and temp_value or 0
    if progress >= 1 and temp > 0 and temp < ctx.config.safety.max_temperature then
      M.mark_stable(ctx, module, now)
      ctx.set_active_startup(nil)
    end
  end
end

function M.update_module_states(ctx)
  local now = os.epoch("utc")
  for _, module in pairs(ctx.modules) do
    local previous = module.state
    local limits = M.update_module_limits(ctx, module)
    if module.type == "reactor" and module.state ~= "OFF" then
      for _, limit in ipairs(limits) do
        if limit == "TEMP" or limit == "WATER" then
          module.state = "ERROR"
          module.progress = 0
          if ctx.current_state() ~= ctx.STATE.SAFE then
            if limit == "WATER" then
              local coolant_diag = module.coolant_safety_diag or {}
              local temp_diag = module.temperature_safety_diag or {}
              local coupled = temp_diag.over_limit and "TEMP_COUPLED" or tostring(coolant_diag.causality or "COOLANT_PRIMARY")
              ctx.log("ERROR", ("Safety trigger: reactor coolant level too low amount=%s max=%s ratio=%s ratio_raw=%s threshold=%s recover_threshold=%s hysteresis=%s source=%s source_method=%s measurement_state=%s stale_fallback=%s low_ticks=%s trip_samples=%s invalid_ticks=%s invalid_grace=%s zero_glitch_pending=%s condition=%s causality=%s temp_value=%s temp_limit=%s temp_condition=%s"):format(
                tostring(coolant_diag.coolant_amount),
                tostring(coolant_diag.coolant_amount_max),
                tostring(coolant_diag.coolant_ratio),
                tostring(coolant_diag.coolant_ratio_raw),
                tostring(coolant_diag.min_water),
                tostring(coolant_diag.recover_threshold),
                tostring(coolant_diag.hysteresis),
                tostring(coolant_diag.source),
                tostring(coolant_diag.source_method),
                tostring(coolant_diag.measurement_state),
                tostring(coolant_diag.stale_fallback_used),
                tostring(coolant_diag.low_ticks),
                tostring(coolant_diag.trip_samples),
                tostring(coolant_diag.invalid_ticks),
                tostring(coolant_diag.invalid_grace_samples),
                tostring(coolant_diag.zero_glitch_pending),
                tostring(coolant_diag.condition),
                tostring(coupled),
                tostring(temp_diag.temperature),
                tostring(temp_diag.max_temperature),
                tostring(temp_diag.condition)
              ))
              ctx.log("ERROR", "Safety ownership=SAFETY subsystem=REACTOR_COOLANT action=ENTER_SAFE")
              ctx.setState(ctx.STATE.SAFE, "SAFETY_COOLANT_LOW")
            else
              local temp_diag = module.temperature_safety_diag or {}
              local coolant_diag = module.coolant_safety_diag or {}
              local coupled = coolant_diag.low_detected and "COOLANT_COUPLED" or "TEMP_PRIMARY"
              ctx.log("ERROR", ("Safety trigger: reactor temperature limit exceeded value=%s limit=%s source=%s fuel_temp=%s casing_temp=%s hysteresis=%s over_limit_ticks=%s trip_samples=%s condition=%s"):format(
                tostring(temp_diag.temperature),
                tostring(temp_diag.max_temperature),
                tostring(temp_diag.source),
                tostring(temp_diag.fuel_temperature),
                tostring(temp_diag.casing_temperature),
                tostring(temp_diag.hysteresis),
                tostring(temp_diag.over_limit_ticks),
                tostring(temp_diag.trip_samples),
                tostring(temp_diag.condition)
              ))
              ctx.log("ERROR", ("Safety trigger correlation: temp_causality=%s coolant_ratio=%s coolant_threshold=%s coolant_condition=%s coolant_source=%s coolant_low_ticks=%s"):format(
                tostring(coupled),
                tostring(coolant_diag.coolant_ratio),
                tostring(coolant_diag.min_water),
                tostring(coolant_diag.condition),
                tostring(coolant_diag.source),
                tostring(coolant_diag.low_ticks)
              ))
              ctx.log("ERROR", "Safety ownership=SAFETY subsystem=REACTOR_TEMP action=ENTER_SAFE")
              ctx.setState(ctx.STATE.SAFE, "SAFETY_TEMPERATURE_HIGH")
            end
          end
          if ctx.node_state_machine:state() ~= ctx.constants.node_states.EMERGENCY then
            ctx.node_state_machine:transition(ctx.constants.node_states.EMERGENCY)
          end
        end
      end
    end
    if module.state == "STABLE" and module.stable_since and (now - module.stable_since > 3000) then
      if ctx.node_state_machine:state() == ctx.constants.node_states.RUNNING then
        module.state = "RUNNING"
      end
    end
    if module.state == "RUNNING" and #module.limits > 0 then
      module.state = "LIMITED"
    elseif module.state == "LIMITED" and #module.limits == 0 then
      module.state = "RUNNING"
    end
    if previous ~= module.state then
      local reason = "STATE_UPDATE"
      if module.state == "RUNNING" and previous == "STABLE" then
        reason = "STABLE_WINDOW_ELAPSED"
      elseif module.state == "LIMITED" then
        reason = "LIMIT_ACTIVE"
      elseif previous == "LIMITED" and module.state == "RUNNING" then
        reason = "LIMIT_CLEARED"
      elseif module.state == "ERROR" then
        reason = "SAFETY_LIMIT"
      end
      ctx.log("INFO", ("Module state %s %s -> %s reason=%s limits=%s"):format(
        tostring(module.id),
        tostring(previous),
        tostring(module.state),
        tostring(reason),
        table.concat(module.limits or {}, ",")
      ))
    end
  end
end

return M
