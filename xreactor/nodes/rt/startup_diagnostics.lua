local safety = require("core.safety")

local M = {}

function M.build_peripheral_summary(summary)
  summary = summary or {}
  local kinds = summary.kinds or {}
  local reactors = kinds.reactor or {}
  local turbines = kinds.turbine or {}
  return string.format(
    "registry total=%d bound=%d missing=%d reactors=%d/%d turbines=%d/%d",
    summary.total or 0,
    summary.bound or 0,
    summary.missing or 0,
    reactors.bound or 0,
    reactors.total or 0,
    turbines.bound or 0,
    turbines.total or 0
  )
end

function M.should_emergency_startup(snapshot, max_temperature, max_rpm)
  local max_temp = snapshot and snapshot.max_temp or nil
  if safety.should_scram({ temperature = max_temp, max_temperature = max_temperature }) then
    return true
  end
  if type(max_rpm) ~= "number" then
    return false
  end
  if snapshot and type(snapshot.avg_rpm) == "number" and snapshot.avg_rpm > max_rpm then
    return true
  end
  for _, entry in pairs(snapshot and snapshot.turbines or {}) do
    if type(entry.rpm) == "number" and entry.rpm > max_rpm then
      return true
    end
  end
  return false
end

function M.handle_startup_timeout(ctx)
  if ctx.startup_watchdog_tripped then
    return true
  end
  ctx.startup_watchdog_tripped = true
  local now = os.epoch("utc")
  local elapsed_s = ctx.startup_started_ms and (now - ctx.startup_started_ms) / 1000 or 0
  local node_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or ctx.config.node_id
  local summary = M.build_peripheral_summary(ctx.devices.registry_summary or ctx.registry:get_summary() or {})
  ctx.log("ERROR", ("Startup watchdog tripped role=%s node=%s elapsed=%.1fs %s"):format(
    tostring(ctx.config.role or "RT"),
    tostring(node_id),
    elapsed_s,
    summary
  ))

  local snapshot = ctx.update_status_snapshot()
  local emergency = M.should_emergency_startup(snapshot, ctx.config.safety.max_temperature, ctx.config.safety.max_rpm)
  local status_level = emergency and ctx.constants.status_levels.EMERGENCY or ctx.constants.status_levels.WARNING
  ctx.broadcast_status(status_level)
  if emergency then
    if ctx.node_state_machine.state() ~= ctx.constants.node_states.EMERGENCY then
      ctx.node_state_machine:transition(ctx.constants.node_states.EMERGENCY)
    end
  else
    if ctx.node_state_machine.state() ~= ctx.constants.node_states.LIMITED then
      ctx.node_state_machine:transition(ctx.constants.node_states.LIMITED)
    end
  end
  -- Fix #3: Direktmutation von ctx.active_startup / ctx.startup_queue umgangen.
  -- main.lua übergibt Setter-Funktionen; wenn vorhanden, diese benutzen,
  -- sonst direkte Zuweisung als Fallback (Abwärtskompatibilität).
  if type(ctx.set_active_startup) == "function" then
    ctx.set_active_startup(nil)
  else
    ctx.active_startup = nil
  end
  if type(ctx.set_startup_queue) == "function" then
    ctx.set_startup_queue({})
  else
    ctx.startup_queue = {}
  end
  return true
end

return M
