local M = {}

local TURBINE_LOG_STATE = {}

-- Fix #10: Erlaubt explizites Zurücksetzen des Log-States (z.B. bei Node-Neustart),
-- damit Logs nach einem Restart nicht fälschlicherweise unterdrückt werden.
function M.reset_log_state(name)
  if name then
    TURBINE_LOG_STATE[name] = nil
  else
    for k in pairs(TURBINE_LOG_STATE) do
      TURBINE_LOG_STATE[k] = nil
    end
  end
end

local function turbine_log_interval(fields)
  local bottleneck = tostring(fields and fields.bottleneck or "NONE")
  if bottleneck == "FLOW_READBACK_LAG" then
    return 20
  end
  if bottleneck ~= "NONE" then
    return 10
  end
  return 30
end

local function should_log_turbine_control(fields)
  local name = tostring(fields and fields.name or "unknown")
  local fingerprint = table.concat({
    tostring(fields and fields.bottleneck or ""),
    tostring(fields and fields.readback_state or ""),
    tostring(fields and fields.write_state or ""),
    tostring(fields and fields.reason or ""),
    tostring(fields and fields.requested_flow or ""),
    tostring(fields and fields.confirmed_flow or ""),
    tostring(fields and fields.target_action or ""),
    tostring(fields and fields.at_max_limit or ""),
    tostring(fields and fields.at_min_limit or "")
  }, "|")

  local rec = TURBINE_LOG_STATE[name]
  if not rec or rec.fingerprint ~= fingerprint then
    TURBINE_LOG_STATE[name] = { fingerprint = fingerprint, count = 1 }
    return true, 1
  end

  rec.count = (tonumber(rec.count) or 0) + 1
  local interval = turbine_log_interval(fields)
  return (rec.count % interval) == 0, rec.count
end

function M.sample_turbine_runtime_metrics(turbine, caps, safe_wrapped_call)
  local steam_input = nil
  if turbine and turbine.getLastInputFluidRate then
    local steam_ok, steam_value = safe_wrapped_call(turbine, "getLastInputFluidRate")
    if steam_ok and type(steam_value) == "number" then
      steam_input = steam_value
    end
  end
  local active_state = nil
  if caps and caps.getActive and turbine and turbine.getActive then
    local active_ok, active_value = safe_wrapped_call(turbine, "getActive")
    if active_ok and type(active_value) == "boolean" then
      active_state = active_value
    end
  end
  return steam_input, active_state
end

function M.capture_turbine_flow_readback(turbine, caps, ctrl, requested_flow, rail_cfg, read_turbine_flow, clamp_turbine_flow)
  local observed_flow, flow_reader = read_turbine_flow(turbine, caps)
  local fast_rereads = math.max(0, rail_cfg.readback_fast_rereads or 2)
  local flow_tolerance = rail_cfg.confirm_tolerance or 1
  local attempt = 0
  while type(observed_flow) == "number"
      and math.abs(requested_flow - observed_flow) > flow_tolerance
      and attempt < fast_rereads do
    local retry_flow, retry_reader = read_turbine_flow(turbine, caps)
    if type(retry_flow) == "number" then
      observed_flow = retry_flow
      flow_reader = retry_reader
    end
    attempt = attempt + 1
  end
  if type(observed_flow) == "number" then
    ctrl.confirmed_flow = clamp_turbine_flow(observed_flow)
    if not ctrl.startup_synced then
      ctrl.startup_synced = true
    end
  end
  return observed_flow, flow_reader, attempt, flow_tolerance
end

function M.update_turbine_flow_tracking(ctrl, requested_flow, confirmed_flow, flow_tolerance, rail_cfg, now_ts, decision, write_state, turbine_regulator)
  local previous_requested = ctrl.pending_expected_flow
  if type(previous_requested) ~= "number" then
    previous_requested = ctrl.last_requested_flow
  end
  local pending_settled = turbine_regulator.flows_match(ctrl.pending_expected_flow, confirmed_flow, flow_tolerance)
  local write_accepted = write_state == "WRITE_ACCEPTED"
  if write_accepted and previous_requested ~= requested_flow then
    ctrl.pending_flow_since = now_ts
    ctrl.pending_expected_flow = requested_flow
    ctrl.pending_retries = 0
    ctrl.pending_retry_stage = 0
  elseif not pending_settled then
    local settle_timeout_s = tonumber(rail_cfg and rail_cfg.settle_timeout_s) or 0
    local pending_since = tonumber(ctrl.pending_flow_since) or now_ts
    local pending_age = math.max(0, now_ts - pending_since)
    if settle_timeout_s > 0 then
      local retry_stage = math.floor(pending_age / settle_timeout_s)
      ctrl.pending_retry_stage = retry_stage
      ctrl.pending_retries = retry_stage
    elseif write_accepted then
      ctrl.pending_retries = (ctrl.pending_retries or 0) + 1
      ctrl.pending_retry_stage = ctrl.pending_retries
    end
  else
    ctrl.pending_retries = 0
    ctrl.pending_retry_stage = 0
    ctrl.pending_flow_since = 0
    ctrl.pending_expected_flow = requested_flow
  end

  local effective_min_samples = rail_cfg.effective_min_samples or 3
  local effective_min_flow, effective_min_changed = turbine_regulator.update_effective_min(
    ctrl,
    requested_flow,
    confirmed_flow,
    effective_min_samples
  )
  if decision and decision.overspeed_brake and requested_flow == 0 and type(confirmed_flow) == "number" and confirmed_flow > flow_tolerance then
    ctrl.overspeed_floor_hits = (ctrl.overspeed_floor_hits or 0) + 1
  else
    ctrl.overspeed_floor_hits = 0
  end
  local readback_state, readback_detail = turbine_regulator.classify_confirmation({
    requested_flow = requested_flow,
    confirmed_flow = confirmed_flow,
    pending_expected_flow = ctrl.pending_expected_flow,
    tolerance = flow_tolerance,
    pending_retries = ctrl.pending_retries,
    readback_retry_cap = rail_cfg.readback_retry_cap or 0,
    settle_timeout_s = rail_cfg.settle_timeout_s or 0,
    pending_since = ctrl.pending_flow_since,
    now_ts = now_ts,
    floor_hint = (ctrl.overspeed_floor_hits or 0) >= effective_min_samples,
    write_state = write_state
  })
  return pending_settled, effective_min_flow, effective_min_changed, readback_state, readback_detail
end

function M.resolve_target_action(reason, decision)
  if decision and decision.overspeed_brake then
    return "OVERSPEED_BRAKE"
  end
  local reason_text = tostring(reason)
  if reason_text == "TARGET_TRIM_UP" then
    return "TARGET_TRIM_UP"
  end
  if reason_text == "TARGET_TRIM_DOWN" then
    return "TARGET_TRIM_DOWN"
  end
  if reason_text:find("MIN_LIMIT_OVERSPEED", 1, true) then
    return "MIN_LIMIT_OVERSPEED"
  end
  if reason_text:find("MAX_LIMIT_UNDERSPEED", 1, true) then
    return "MAX_LIMIT_UNDERSPEED"
  end
  return "TRACKING_ACTIVE"
end

function M.log_turbine_control_metrics(fields, log)
  -- TurbineCtrl DEBUG deaktiviert: zu viel Output (repeat_count=1000+ pro Turbine)
  return
  log("DEBUG", "TurbineCtrl name=" .. tostring(fields.name)
      .. " repeat_count=" .. tostring(repeat_count)
      .. " rpm=" .. tostring(fields.rpm)
      .. " rpm_smooth=" .. tostring(fields.smoothed_rpm)
      .. " target_rpm=" .. tostring(fields.target_rpm)
      .. " old_flow=" .. tostring(fields.old_flow)
      .. " requested_flow=" .. tostring(fields.requested_flow)
      .. " confirmed_flow=" .. tostring(fields.confirmed_flow)
      .. " new_flow=" .. tostring(fields.requested_flow)
      .. " direction=" .. tostring(fields.direction)
      .. " reason=" .. tostring(fields.reason)
      .. " step=" .. tostring(fields.step)
      .. " clamp_min=" .. tostring(fields.applied_min)
      .. " clamp_max=" .. tostring(fields.applied_max)
      .. " set_api=" .. tostring(fields.setter)
      .. " set_called=" .. tostring(fields.set_called)
      .. " set_ok=" .. tostring(fields.set_ok)
      .. " write_state=" .. tostring(fields.write_state)
      .. " write_detail=" .. tostring(fields.write_detail)
      .. " flow_read=" .. tostring(fields.observed_flow)
      .. " flow_api=" .. tostring(fields.flow_reader)
      .. " flow_read_attempts=" .. tostring(1 + fields.attempt)
      .. " flow_settled=" .. tostring(fields.flow_settled)
      .. " pending_settled=" .. tostring(fields.pending_settled)
      .. " pending_retries=" .. tostring(fields.pending_retries)
      .. " pending_retry_stage=" .. tostring(fields.pending_retry_stage)
      .. " pending_age_s=" .. tostring(fields.pending_age_s)
      .. " settle_timeout_s=" .. tostring(fields.settle_timeout_s)
      .. " pending_since=" .. tostring(fields.pending_flow_since)
      .. " pending_expected_flow=" .. tostring(fields.pending_expected_flow)
      .. " cooldown_deferred=" .. tostring(fields.cooldown_deferred)
      .. " cooldown_defer_reason=" .. tostring(fields.cooldown_defer_reason)
      .. " effective_min_flow=" .. tostring(fields.effective_min_flow)
      .. " effective_min_applied=" .. tostring(fields.effective_min_applied)
      .. " mode=" .. tostring(fields.mode)
      .. " regulator_state=" .. tostring(fields.target_action)
      .. " target_zone_state=" .. tostring(fields.target_zone_state)
      .. " target_band_active=" .. tostring(fields.target_holding_active)
      .. " target_band_status=" .. tostring(fields.target_band_status)
      .. " target_band_reason=" .. tostring(fields.target_band_reason)
      .. " target_band_error=" .. tostring(fields.target_band_error)
      .. " target_band_live_error=" .. tostring(fields.target_band_live_error)
      .. " target_band_smoothed_error=" .. tostring(fields.target_band_smoothed_error)
      .. " target_holding_active=" .. tostring(fields.hold_active)
      .. " target_trim_active=" .. tostring(fields.active_trim)
      .. " flow_trim_direction=" .. tostring(fields.flow_trim_direction)
      .. " coil=" .. tostring(fields.inductor_engaged)
      .. " coil_api=" .. tostring(fields.inductor_state_api)
      .. " overspeed_brake=" .. tostring(fields.overspeed_brake)
      .. " overspeed_rpm=" .. tostring(fields.overspeed_rpm)
      .. " overspeed_threshold_rpm=" .. tostring(fields.overspeed_threshold_rpm)
      .. " overspeed_coil_ok=" .. tostring(fields.overspeed_coil_ok)
      .. " overspeed_coil_reason=" .. tostring(fields.overspeed_coil_reason)
      .. " overspeed_floor_hits=" .. tostring(fields.overspeed_floor_hits)
      .. " readback_state=" .. tostring(fields.readback_state)
      .. " readback_detail=" .. tostring(fields.readback_detail)
      .. " steam_input=" .. tostring(fields.steam_input)
      .. " active=" .. tostring(fields.active_state)
      .. " max_flow_limit=" .. tostring(fields.max_flow_limit)
      .. " at_max_flow=" .. tostring(fields.at_max_limit)
      .. " at_min_flow=" .. tostring(fields.at_min_limit)
      .. " down_regulation_limited=" .. tostring(fields.down_regulation_limited)
      .. " up_regulation_limited=" .. tostring(fields.up_regulation_limited)
      .. " flow_limit_state=" .. tostring(fields.flow_limit_state)
      .. " bottleneck=" .. tostring(fields.bottleneck)
      .. " bottleneck_detail=" .. tostring(fields.bottleneck_detail))
end

return M
