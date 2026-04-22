local M = {}

function M.master_peer_state(ctx)
  local peers = ctx.comms and ctx.comms:get_peers() or {}
  for _, data in pairs(peers) do
    if data.role == ctx.constants.roles.MASTER then
      return data
    end
  end
  return nil
end

function M.is_master_connected(ctx)
  local peer = M.master_peer_state(ctx)
  if peer then
    return not peer.down, peer.age
  end
  if ctx.master_seen then
    local age = (os.epoch("utc") - ctx.master_seen) / 1000
    return age <= (ctx.hb * 5), age
  end
  return false, nil
end

function M.build_health_payload(ctx)
  local reasons = {}
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary()
  local binding_policy = ctx.binding.build_policy(ctx.configured_reactors, ctx.configured_turbines)
  local bound_reactors = summary.kinds.reactor and summary.kinds.reactor.bound or 0
  local bound_turbines = summary.kinds.turbine and summary.kinds.turbine.bound or 0
  if bound_reactors == 0 then
    reasons[ctx.health.reasons.NO_REACTOR] = true
    ctx.warn_once("reactors_missing_health", ctx.binding.missing_devices_message("reactor", binding_policy))
  end
  if bound_turbines == 0 then
    reasons[ctx.health.reasons.NO_TURBINE] = true
    ctx.warn_once("turbines_missing_health", ctx.binding.missing_devices_message("turbine", binding_policy))
  end
  if ctx.devices.discovery_failed or ctx.devices.registry_load_error then
    reasons[ctx.health.reasons.DISCOVERY_FAILED] = true
  end
  if ctx.devices.proto_mismatch then
    reasons[ctx.health.reasons.PROTO_MISMATCH] = true
  end
  if ctx.startup_watchdog_tripped then
    reasons[ctx.health.reasons.CONTROL_DEGRADED] = true
  end
  local connected = M.is_master_connected(ctx)
  if not connected then
    reasons[ctx.health.reasons.COMMS_DOWN] = true
  end
  local status = next(reasons) and ctx.health.status.DEGRADED or ctx.health.status.OK
  ctx.rt_health.status = status
  ctx.rt_health.reasons = reasons
  ctx.rt_health.last_seen_ts = os.epoch("utc")
  ctx.rt_health.bindings = {
    reactors = bound_reactors,
    turbines = bound_turbines
  }
  ctx.rt_health.capabilities = { reactors = ctx.configured_caps.reactors, turbines = ctx.configured_caps.turbines }
  return {
    status = ctx.rt_health.status,
    reasons = ctx.health.reasons_list(ctx.rt_health),
    last_seen_ts = ctx.rt_health.last_seen_ts,
    bindings = ctx.rt_health.bindings,
    capabilities = ctx.rt_health.capabilities
  }
end

return M
