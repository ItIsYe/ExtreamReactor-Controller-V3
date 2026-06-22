local utils = require("core.utils")

local function log_command(ctx, level, message)
  if type(ctx.log) == "function" then
    local ok = pcall(ctx.log, level or "INFO", message)
    if ok then return end
  end
  utils.log("RT", message, level or "INFO")
end

-- R1: number_or_nil aus core.utils, mit Fallback für ältere utils-Versionen
local number_or_nil = utils.number_or_nil or function(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then local n = tonumber(v); if n then return n end end
  return nil
end

local function get_learning(ctx)
  -- Support both direct field (status_snapshot ctx) and getter (command ctx).
  if ctx.get_capacity_learning then
    return ctx.get_capacity_learning()
  end
  return ctx.capacity_learning
end

-- Prüft ob das Capacity-Learning eine gültige Messung hat.
-- Erst dann darf der Master Prozentvorgaben senden (sonst wäre
-- power_percent relativ zu einer unbekannten Kapazität sinnlos).
local function capacity_learning_locked(ctx)
  local learning = get_learning(ctx)
  return type(learning) == "table"
    and learning.ready == true
    and number_or_nil(learning.max_output)
    and number_or_nil(learning.max_output) > 0
end

local function value_summary(value)
  if type(value) == "table" then
    local parts = {}
    if value.power_target_percent ~= nil then parts[#parts + 1] = "pct=" .. tostring(value.power_target_percent) end
    if value.assignment_state    ~= nil then parts[#parts + 1] = "state=" .. tostring(value.assignment_state) end
    if value.desired_node_state  ~= nil then parts[#parts + 1] = "node_state=" .. tostring(value.desired_node_state) end
    if value.shutdown_stage      ~= nil then parts[#parts + 1] = "shutdown=" .. tostring(value.shutdown_stage) end
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
  if not capacity_learning_locked(ctx) then
    local learning = ctx.capacity_learning or {}
    return record({
      ok = false,
      error = "capacity learning not locked",
      reason_code = "CAPACITY_LEARNING",
      capacity_ready = false,
      capacity_source = learning.reason or "LEARNING",
      capacity_stable_samples = learning.at_target or 0,
      command_value = value
    })
  end

  -- Master sendet nur den Prozentwert — RT berechnet Flow, Coil,
  -- Reaktor-Stab vollständig autonom daraus.
  local targets = ctx.targets
  local pct = number_or_nil(value.power_target_percent)
  if pct then
    pct = math.max(0, math.min(100, pct))
    targets.power_percent = pct
    log_command(ctx, "INFO", ("Setpoint applied percent=%.1f"):format(pct))
  end
  if value.assignment_state ~= nil then
    targets.assignment_state = tostring(value.assignment_state)
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
        shutdown_stage = value.shutdown_stage,
        command_value = value
      })
    end
    return record({
      ok = true,
      transition = "ALREADY_IN_STATE",
      current_state = current,
      desired_node_state = desired_state,
      shutdown_stage = value.shutdown_stage,
      command_value = value
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
    end,
    -- REMOTE_UPDATE: Nicht direkt ausfuehren — Flag setzen fuer den
    -- Haupt-Thread. CC:Tweaked http.get() ist async und sendet http_success/
    -- http_failure Events. Diese koennen nicht ankommen wenn wir uns bereits
    -- in einem os.pullEvent-Handler (modem_message) befinden — der Installer
    -- wuerde ewig blockieren. Deferred-Ausfuehrung nach dem aktuellen Tick
    -- im Haupt-Thread loest das Problem.
    ["REMOTE_UPDATE"] = function(_, ctx)
      if type(ctx.set_pending_remote_update) == "function" then
        ctx.set_pending_remote_update()
        if type(ctx.log) == "function" then
          ctx.log("WARN", "Remote-Update: Command empfangen, starte nach aktuellem Tick...")
        end
      else
        -- Fallback fuer aeltere ctx-Versionen ohne deferred support
        require("core.remote_update").handle_command({
          log_fn = type(ctx.log) == "function" and ctx.log or nil,
        })
      end
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
    -- REMOTE_UPDATE darf auch im SAFE-Mode laufen (Update könnte genau den
    -- Bug beheben, der zum SAFE-Mode geführt hat).
    if command.target == "REMOTE_UPDATE" then
      local handler = dispatch_by_target["REMOTE_UPDATE"]
      handler(command, ctx)
      return record({ ok = true })
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
