local function set_setpoints(command, ctx, record)
  if ctx.get_current_state() ~= ctx.STATE.MASTER then
    return record({ ok = false, error = "autonom: ignoring setpoints", reason_code = "INVALID_STATE" })
  end

  local value = command.value or {}
  local targets = ctx.targets
  if type(value.target_rpm) == "number" then
    targets.rpm = value.target_rpm
  end
  if type(value.power_target) == "number" then
    targets.power = value.power_target
  end
  if type(value.steam_target) == "number" then
    targets.steam = value.steam_target
  end
  if value.enable_reactors ~= nil then
    targets.enable_reactors = value.enable_reactors and true or false
  end
  if value.enable_turbines ~= nil then
    targets.enable_turbines = value.enable_turbines and true or false
  end
  ctx.request_startup_if_needed("SET_SETPOINTS")
  return nil
end

local function set_scalar_target(command, ctx, key, fallback)
  if ctx.get_current_state() ~= ctx.STATE.MASTER then
    return
  end
  if fallback ~= nil then
    ctx.targets[key] = command.value or fallback
  else
    ctx.targets[key] = command.value
  end
end

local function transition_mode(command, ctx)
  if ctx.get_current_state() ~= ctx.STATE.MASTER then
    return
  end
  local states = ctx.get_states()
  if states[command.value] then
    ctx.node_state_machine:transition(command.value)
  end
end

local function startup_stage(command, ctx, record)
  if ctx.get_current_state() ~= ctx.STATE.MASTER then
    return record({ ok = false, error = "autonom: ignoring startup", reason_code = "INVALID_STATE" })
  end

  local value = command.value or {}
  local module, detail = ctx.start_module(value.module_id, value.module_type, value.ramp_profile)
  if not module then
    ctx.add_alarm(ctx.get_network_id(), "WARNING", "Startup rejected: " .. (detail or "unknown"))
    return record({ ok = false, error = detail or "startup rejected", reason_code = "STARTUP_REJECTED" })
  end
  return record({ ok = true, module_id = module.id, detail = detail })
end

local function make_dispatch()
  return {
    ["SET_MODE"] = function(command, ctx)
      ctx.apply_mode(command.value)
      return nil
    end,
    ["SET_SETPOINTS"] = set_setpoints,
    ["POWER_TARGET"] = function(command, ctx)
      set_scalar_target(command, ctx, "power")
      return nil
    end,
    ["STEAM_TARGET"] = function(command, ctx)
      set_scalar_target(command, ctx, "steam")
      return nil
    end,
    ["TURBINE_RPM"] = function(command, ctx)
      set_scalar_target(command, ctx, "rpm", ctx.TARGET_RPM)
      return nil
    end,
    ["MODE"] = function(command, ctx)
      transition_mode(command, ctx)
      return nil
    end,
    ["STARTUP_STAGE"] = startup_stage,
    ["REQUEST_STARTUP_MODULE"] = startup_stage,
    ["SCRAM"] = function(_, ctx)
      ctx.apply_mode(ctx.STATE.SAFE)
      return nil
    end
  }
end

local dispatch_by_target = make_dispatch()

local function new(ctx)
  local protocol = ctx.protocol

  local function record(result)
    ctx.set_last_command(result and (result.ok and "ok" or result.error or "error") or "error")
    ctx.set_last_command_ts(os.epoch("utc"))
    return result
  end

  return function(message)
    if not protocol.is_for_node(message, ctx.get_network_id()) then
      return
    end
    if not protocol.is_proto_compatible(message.proto_ver) then
      return record({ ok = false, error = "proto mismatch", reason_code = "PROTO_MISMATCH" })
    end

    local payload = type(message.payload) == "table" and message.payload or nil
    local command = payload and payload.command
    if type(command) ~= "table" then
      return record({ ok = false, error = "invalid command", reason_code = "INVALID_COMMAND" })
    end
    if ctx.get_current_state() == ctx.STATE.SAFE then
      return record({ ok = false, error = "safe: ignoring commands", reason_code = "SAFE_MODE" })
    end

    ctx.note_master_seen()

    local target_name = command.target
    local handler = target_name and dispatch_by_target[target_name]
    if not handler then
      return record({ ok = false, error = "unsupported command", reason_code = "UNSUPPORTED_COMMAND" })
    end

    local result = handler(command, ctx, record)
    if result ~= nil then
      return result
    end
    return record({ ok = true })
  end
end

return {
  new = new
}
