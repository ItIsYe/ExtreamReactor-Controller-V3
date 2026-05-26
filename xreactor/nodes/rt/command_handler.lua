local function log_command(ctx, level, message)
  if type(ctx.log) == "function" then
    pcall(ctx.log, level or "INFO", message)
  end
end

local function value_summary(value)
  if type(value) == "table" then
    local parts = {}
    if value.target_rpm ~= nil then parts[#parts + 1] = "target_rpm=" .. tostring(value.target_rpm) end
    if value.power_target ~= nil then parts[#parts + 1] = "power_target=" .. tostring(value.power_target) end
    if value.steam_target ~= nil then parts[#parts + 1] = "steam_target=" .. tostring(value.steam_target) end
    if value.enable_reactors ~= nil then parts[#parts + 1] = "enable_reactors=" .. tostring(value.enable_reactors) end
    if value.enable_turbines ~= nil then parts[#parts + 1] = "enable_turbines=" .. tostring(value.enable_turbines) end
    if value.assignment_state ~= nil then parts[#parts + 1] = "assignment_state=" .. tostring(value.assignment_state) end
    if value.desired_node_state ~= nil then parts[#parts + 1] = "desired_node_state=" .. tostring(value.desired_node_state) end
    if #parts > 0 then return table.concat(parts, ",") end
    return "table"
  end
  return tostring(value)
end

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
  local desired_state = value.desired_node_state
  local machine = ctx.node_state_machine
  local states = ctx.get_states()
  if desired_state and not states[desired_state] then
    return record({ ok = false, error = "invalid desired_node_state", reason_code = "INVALID_STATE", desired_node_state = desired_state })
  end
  if desired_state and machine and states[desired_state] then
    local current = machine:state()
    if current ~= desired_state then
      machine:transition(desired_state)
      return record({
        ok = true,
        transition = "REQUESTED",
        current_state = current,
        desired_node_state = desired_state,
        shutdown_stage = value.shutdown_stage
      })
    end
    return record({
      ok = true,
      transition = "ALREADY_IN_STATE",
      current_state = current,
      desired_node_state = desired_state,
      shutdown_stage = value.shutdown_stage
    })
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

  local function log_result(target_name, result)
    if not result then return end
    local level = result.ok == false and "WARN" or "INFO"
    if result.ok == false then
      log_command(ctx, level, ("Command rejected target=%s reason=%s error=%s current_mode=%s"):format(
        tostring(target_name), tostring(result.reason_code or "UNKNOWN"), tostring(result.error or "unknown"), tostring(ctx.get_current_state())
      ))
    else
      log_command(ctx, level, ("Command applied target=%s transition=%s desired_node_state=%s current_mode=%s"):format(
        tostring(target_name), tostring(result.transition or "APPLIED"), tostring(result.desired_node_state or "-"), tostring(ctx.get_current_state())
      ))
    end
  end

  return function(message)
    if not protocol.is_for_node(message, ctx.get_network_id()) then
      return
    end
    if not protocol.is_proto_compatible(message.proto_ver) then
      local result = record({ ok = false, error = "proto mismatch", reason_code = "PROTO_MISMATCH" })
      log_result("UNKNOWN", result)
      return result
    end

    local payload = type(message.payload) == "table" and message.payload or nil
    local command = payload and payload.command
    if type(command) ~= "table" then
      local result = record({ ok = false, error = "invalid command", reason_code = "INVALID_COMMAND" })
      log_result("UNKNOWN", result)
      return result
    end
    if ctx.get_current_state() == ctx.STATE.SAFE then
      local result = record({ ok = false, error = "safe: ignoring commands", reason_code = "SAFE_MODE" })
      log_result(command.target or "UNKNOWN", result)
      return result
    end

    ctx.note_master_seen()

    local target_name = command.target
    log_command(ctx, "INFO", ("Command received target=%s value=%s from=%s current_mode=%s node=%s"):format(
      tostring(target_name), value_summary(command.value), tostring(message.sender_id or message.src or "?"), tostring(ctx.get_current_state()), tostring(ctx.get_network_id())
    ))

    local handler = target_name and dispatch_by_target[target_name]
    if not handler then
      local result = record({ ok = false, error = "unsupported command", reason_code = "UNSUPPORTED_COMMAND" })
      log_result(target_name or "UNKNOWN", result)
      return result
    end

    local result = handler(command, ctx, record)
    if result == nil then
      result = record({ ok = true })
    end
    log_result(target_name, result)
    return result
  end
end

return {
  new = new
}
