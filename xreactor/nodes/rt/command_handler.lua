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

-- Fix: neues capacity_learning Modul (nodes/rt/capacity_learning.lua) setzt
-- .ready = true, nicht .locked (altes Feld aus der Lock-basierten Logik).
-- Vorher: SET_SETPOINTS wurde IMMER abgelehnt ("capacity learning not locked"),
-- weil learning.locked immer nil war — Master konnte nie Vorgaben senden.
local function capacity_learning_locked(ctx)
  local learning = get_learning(ctx)
  return type(learning) == "table"
    and (learning.ready == true or learning.locked == true)
    and number_or_nil(learning.max_output)
    and number_or_nil(learning.max_output) > 0
end

local function current_capacity(ctx)
  local learning = get_learning(ctx)
  if type(learning) == "table"
      and (learning.ready == true or learning.locked == true) then
    local max_output = number_or_nil(learning.max_output)
    if max_output and max_output > 0 then return max_output, "learned" end
  end
  local targets = ctx.targets or {}
  local previous = number_or_nil(targets.capacity_max)
  if previous and previous > 0 then return previous, "target-cache" end
  return nil, "unavailable"
end

local function value_summary(value)
  if type(value) == "table" then
    local parts = {}
    if value.target_rpm ~= nil then parts[#parts + 1] = "target_rpm=" .. tostring(value.target_rpm) end
    if value.power_target_percent ~= nil then parts[#parts + 1] = "power_target_percent=" .. tostring(value.power_target_percent) end
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
  if not capacity_learning_locked(ctx) then
    local learning = ctx.capacity_learning or {}
    return record({
      ok = false,
      error = "capacity learning not locked",
      reason_code = "CAPACITY_LEARNING",
      capacity_ready = false,
      capacity_source = learning.reason or "LEARNING",
      -- Fix: stable_samples existiert nicht mehr im neuen Learning-State,
      -- at_target ist der neue Name (Turbinen die gerade am Ziel sind).
      capacity_stable_samples = learning.at_target or learning.stable_samples or 0,
      command_value = value
    })
  end

  local targets = ctx.targets
  if type(value.target_rpm) == "number" then
    targets.rpm = value.target_rpm
  end
  local pct = number_or_nil(value.power_target_percent)
  if pct then
    pct = math.max(0, math.min(100, pct))
    targets.power_percent = pct
    local capacity, source = current_capacity(ctx)
    if capacity and capacity > 0 then
      targets.power = capacity * (pct / 100)
      targets.capacity_max = capacity
      targets.capacity_source = source
      log_command(ctx, "INFO", ("Percent setpoint applied percent=%.1f capacity=%.2f source=%s local_power=%.2f"):format(pct, capacity, tostring(source), targets.power))
    elseif type(value.power_target) == "number" then
      targets.power = value.power_target
      targets.capacity_source = "fallback-absolute"
      log_command(ctx, "WARN", ("Percent setpoint capacity unavailable; using absolute fallback power=%.2f percent=%.1f"):format(targets.power, pct))
    else
      targets.power = 0
      targets.capacity_source = "unavailable"
      log_command(ctx, "WARN", ("Percent setpoint capacity unavailable; target forced to 0 percent=%.1f"):format(pct))
    end
  elseif type(value.power_target) == "number" then
    targets.power = value.power_target
    targets.power_percent = nil
    targets.capacity_source = "absolute"
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
  -- Fix: assignment_state wurde vom Master gesendet und nur fürs Logging
  -- ausgewertet (value_summary), aber nie tatsächlich in targets gespeichert.
  -- Die UI (monitor_ui.lua render_overview) liest model.assignment_state
  -- für den STANDBY-Indikator (z.B. "shutdown"/"unavailable") — ohne diese
  -- Zeile war das Feld immer nil und der Indikator faktisch unerreichbar.
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
